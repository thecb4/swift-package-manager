/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic
import TSCUtility
import PackageModel
import PackageGraph

/// llbuild manifest file generator for a build plan.
public final class LLBuildManifestGenerator {

    /// The name of the llbuild target that builds all products and targets (excluding tests).
    public static let llbuildMainTargetName = "main"

    /// The name of the llbuild target that builds all products and targets (including tests).
    public static let llbuildTestTargetName = "test"

    /// The build plan to work on.
    public let plan: BuildPlan

    /// The manifest client name.
    public let client: String

    /// The nodes with custom attributes.
    private var nodes: [Node] = []

    /// Create a new generator with a build plan.
    public init(_ plan: BuildPlan, client: String) {
        self.plan = plan
        self.client = client
    }

    private struct Node {
        var value: String
        var isDirectoryStructure: Bool
    }

    /// A structure for targets in the manifest.
    private struct Targets {

        /// Main target.
        private(set) var main = Target(name: LLBuildManifestGenerator.llbuildMainTargetName)

        /// Test target.
        private(set) var test = Target(name: LLBuildManifestGenerator.llbuildTestTargetName)

        /// All targets.
        var allTargets: [Target] {
            return [main, test] + otherTargets.sorted(by: { $0.name < $1.name })
        }

        /// All commands.
        var allCommands = SortedArray<Command>(areInIncreasingOrder: <)

        /// Other targets.
        private var otherTargets: [Target] = []

        mutating func addOtherTarget(_ target: Target) {
            otherTargets.append(target)
        }

        /// Append a command.
        mutating func append(_ target: Target, buildByDefault: Bool, isTest: Bool) {
            // Create a phony command with a virtual output node that represents the target.
            let virtualNodeName = "<\(target.name)>"
            let phonyTool = PhonyTool(inputs: target.outputs.values, outputs: [virtualNodeName])
            let phonyCommand = Command(name: "<C.\(target.name)>", tool: phonyTool)

            // Use the phony command as dependency.
            var newTarget = target
            newTarget.outputs.insert(virtualNodeName)
            newTarget.cmds.insert(phonyCommand)
            otherTargets.append(newTarget)

            if buildByDefault {
                if !isTest {
                    main.outputs += newTarget.outputs
                    main.cmds += newTarget.cmds
                }

                // Always build everything for the test target.
                test.outputs += newTarget.outputs
                test.cmds += newTarget.cmds
            }

            allCommands += newTarget.cmds
        }
    }

    /// Generate manifest at the given path.
    public func generateManifest(at path: AbsolutePath) throws {
        var targets = Targets()

        addPackageStructureCommand(&targets)

        // Create commands for all target description in the plan.
        for (target, description) in plan.targetMap {
            switch description {
            case .swift(let description):
                // Only build targets by default if they are reachabe from a root target.
                targets.append(createSwiftCompileTarget(description),
                    buildByDefault: plan.graph.isInRootPackages(target),
                    isTest: description.isTestTarget)
            case .clang(let description):
                targets.append(try createClangCompileTarget(description),
                    buildByDefault: plan.graph.isInRootPackages(target),
                    isTest: description.isTestTarget)
            }
        }

        addTestFileGeneration(&targets)

        // Create command for all products in the plan.
        for (product, description) in plan.productMap {
            // Only build products by default if they are reachabe from a root target.
            targets.append(createProductTarget(description),
                buildByDefault: plan.graph.reachableProducts.contains(product),
                isTest: product.type == .test)
        }

        // Write the manifest.
        let stream = BufferedOutputByteStream()
        stream <<< """
            client:
              name: \(client)
            tools: {}
            targets:\n
            """
        for target in targets.allTargets {
            stream <<< "  " <<< Format.asJSON(target.name)
            stream <<< ": " <<< Format.asJSON(target.outputs.values) <<< "\n"
        }

        stream <<< "default: " <<< Format.asJSON(targets.main.name) <<< "\n"

        if !nodes.isEmpty {
            stream <<< "nodes: \n"
        }
        for node in nodes {
            stream <<< "  " <<< Format.asJSON(node.value) <<< ":\n"
            if node.isDirectoryStructure {
                stream <<< "    is-directory-structure: true\n"
            }
        }

        stream <<< "commands: \n"
        for command in targets.allCommands.sorted(by: { $0.name < $1.name }) {
            stream <<< "  " <<< Format.asJSON(command.name) <<< ":\n"
            command.tool.append(to: stream)
            stream <<< "\n"
        }

        try localFileSystem.writeFileContents(path, bytes: stream.bytes)
    }

    private func addTestFileGeneration(_ targets: inout Targets) {
        for target in plan.targets {
            guard case .swift(let target) = target, target.isTestTarget, target.testDiscoveryTarget else { continue }
            let testDiscoveryTarget = target

            let testTargets = testDiscoveryTarget.target.dependencies.compactMap{ $0.target }.compactMap{ plan.targetMap[$0] }
            let objectFiles = testTargets.flatMap{ $0.objects }.map{ $0.pathString }.sorted()
            let outputs = testDiscoveryTarget.target.sources.paths
            let tool = TestDiscoveryTool(inputs: objectFiles, outputs: outputs.map{ $0.pathString })

            let cmdName = outputs.first{ $0.basename == "main.swift" }!.pathString
            targets.allCommands.insert(Command(name: cmdName, tool: tool))
            testDiscoveryCommands[cmdName] = tool
        }
    }

    private func addPackageStructureCommand(_ targets: inout Targets) {
        var inputs: [String] = []

        for package in plan.graph.rootPackages {
            let directoryStructureInputs = package.targets.map {
                $0.sources.root.pathString + "/"
            }.sorted()
            self.nodes += directoryStructureInputs.map{ Node(value: $0, isDirectoryStructure: true) }

            inputs = directoryStructureInputs

            // FIXME: Need to handle version-specific manifests.
            inputs += [package.manifest.path.pathString]

            // FIXME: This won't be the location of Package.resolved for multiroot packages.
            inputs += [package.path.appending(component: "Package.resolved").pathString]

            // FIXME: Add config file as an input
        }

        let name = "<PackageStructure>"
        let tool = PackageStructureTool(inputs: inputs, outputs: [name])
        let cmd = Command(name: name, tool: tool)

        var target = Target(name: "PackageStructure")
        target.outputs += tool.outputs
        targets.addOtherTarget(target)

        targets.allCommands.insert(cmd)
    }

    /// Map of command -> tool that is used during the build for in-process tools.
    public private(set) var testDiscoveryCommands: [String: TestDiscoveryTool] = [:]

    /// Create a llbuild target for a product description.
    private func createProductTarget(_ buildProduct: ProductBuildDescription) -> Target {
        let tool: ToolProtocol
        // Create archive tool for static library and shell tool for rest of the products.
        if buildProduct.product.type == .library(.static) {
            tool = ArchiveTool(
                inputs: buildProduct.objects.map({ $0.pathString }),
                outputs: [buildProduct.binary.pathString])
        } else {
            let inputs = buildProduct.objects + buildProduct.dylibs.map({ $0.binary })
            tool = ShellTool(
                description: "Linking \(buildProduct.binary.prettyPath())",
                inputs: inputs.map({ $0.pathString }),
                outputs: [buildProduct.binary.pathString],
                args: buildProduct.linkArguments(),
                allowMissingInputs: false
            )
        }

        let buildConfig = plan.buildParameters.configuration.dirname
        var target = Target(name: buildProduct.product.getLLBuildTargetName(config: buildConfig))
        target.outputs.insert(contentsOf: tool.outputs)
        target.cmds.insert(Command(name: buildProduct.product.getCommandName(config: buildConfig), tool: tool))
        return target
    }

    /// Create a llbuild target for a Swift target description.
    private func createSwiftCompileTarget(_ target: SwiftTargetBuildDescription) -> Target {
        // Compute inital inputs.
        var inputs = SortedArray<String>()
        inputs += target.sources.map{ $0.pathString }

        func addStaticTargetInputs(_ target: ResolvedTarget) {
            // Ignore C Modules.
            if target.underlyingTarget is SystemLibraryTarget { return }

            // Depend on the binary for executable targets.
            if target.type == .executable {
                // FIXME: Optimize.
                let _product = plan.graph.allProducts.first {
                    $0.type == .executable && $0.executableModule == target
                }
                if let product = _product {
                    inputs += [plan.productMap[product]!.binary.pathString]
                }
                return
            }

            switch plan.targetMap[target] {
            case .swift(let target)?:
                inputs.insert(target.moduleOutputPath.pathString)
            case .clang(let target)?:
                inputs += target.objects.map({ $0.pathString })
            case nil:
                fatalError("unexpected: target \(target) not in target map \(plan.targetMap)")
            }
        }

        for dependency in target.target.dependencies {
            switch dependency {
            case .target(let target):
                addStaticTargetInputs(target)

            case .product(let product):
                switch product.type {
                case .executable, .library(.dynamic):
                    // Establish a dependency on binary of the product.
                    inputs += [plan.productMap[product]!.binary.pathString]

                // For automatic and static libraries, add their targets as static input.
                case .library(.automatic), .library(.static):
                    for target in product.targets {
                        addStaticTargetInputs(target)
                    }
                case .test:
                    break
                }
            }
        }

        let buildConfig = plan.buildParameters.configuration.dirname
        var buildTarget = Target(name: target.target.getLLBuildTargetName(config: buildConfig))
        // The target only cares about the module output.
        buildTarget.outputs.insert(target.moduleOutputPath.pathString)
        let tool = SwiftCompilerTool(target: target, inputs: inputs.values)
        buildTarget.cmds.insert(Command(name: target.target.getCommandName(config: buildConfig), tool: tool))

        // Add commands to perform the module wrapping Swift modules when debugging statergy is `modulewrap`.
        if plan.buildParameters.debuggingStrategy == .modulewrap {
            let modulewrapTool = ShellTool(
                description: "Wrapping AST for \(target.target.name) for debugging",
                inputs: [target.moduleOutputPath.pathString],
                outputs: [target.wrappedModuleOutputPath.pathString],
                args: [target.buildParameters.toolchain.swiftCompiler.pathString,
                       "-modulewrap", target.moduleOutputPath.pathString, "-o",
                       target.wrappedModuleOutputPath.pathString],
                allowMissingInputs: false)
            buildTarget.cmds.insert(Command(name: target.wrappedModuleOutputPath.pathString, tool: modulewrapTool))
        }

        return buildTarget
    }

    /// Create a llbuild target for a Clang target description.
    private func createClangCompileTarget(_ target: ClangTargetBuildDescription) throws -> Target {

        let standards = [
            (target.clangTarget.cxxLanguageStandard, SupportedLanguageExtension.cppExtensions),
            (target.clangTarget.cLanguageStandard, SupportedLanguageExtension.cExtensions),
        ]

        var externalDependencies = SortedArray<String>()

        func addStaticTargetInputs(_ target: ResolvedTarget) {
            if case .swift(let desc)? = plan.targetMap[target], target.type == .library {
                externalDependencies.insert(desc.moduleOutputPath.pathString)
            }
        }

        for dependency in target.target.dependencies {
            switch dependency {
            case .target(let target):
                addStaticTargetInputs(target)

            case .product(let product):
                switch product.type {
                case .executable, .library(.dynamic):
                    // Establish a dependency on binary of the product.
                    externalDependencies += [plan.productMap[product]!.binary.pathString]

                case .library(.automatic), .library(.static):
                    for target in product.targets {
                        addStaticTargetInputs(target)
                    }
                case .test:
                    break
                }
            }
        }

        let commands: [Command] = try target.compilePaths().map({ path in
            var args = target.basicArguments()
            args += ["-MD", "-MT", "dependencies", "-MF", path.deps.pathString]

            // Add language standard flag if needed.
            if let ext = path.source.extension {
                for (standard, validExtensions) in standards {
                    if let languageStandard = standard, validExtensions.contains(ext) {
                        args += ["-std=\(languageStandard)"]
                    }
                }
            }

            args += ["-c", path.source.pathString, "-o", path.object.pathString]
            let clang = ClangTool(
                desc: "Compiling \(target.target.name) \(path.filename)",
                inputs: externalDependencies + [path.source.pathString],
                outputs: [path.object.pathString],
                args: [try plan.buildParameters.toolchain.getClangCompiler().pathString] + args,
                deps: path.deps.pathString)
            return Command(name: path.object.pathString, tool: clang)
        })

        // For Clang, the target requires all command outputs.
        var buildTarget = Target(name: target.target.getLLBuildTargetName(config: plan.buildParameters.configuration.dirname))
        buildTarget.outputs.insert(contentsOf: commands.flatMap({ $0.tool.outputs }))
        buildTarget.cmds += commands
        return buildTarget
    }
}

extension ResolvedTarget {
    public func getCommandName(config: String) -> String {
       return "C." + getLLBuildTargetName(config: config)
    }

    public func getLLBuildTargetName(config: String) -> String {
        return "\(name)-\(config).module"
    }
}

extension ResolvedProduct {
    public func getLLBuildTargetName(config: String) -> String {
        switch type {
        case .library(.dynamic):
            return "\(name)-\(config).dylib"
        case .test:
            return "\(name)-\(config).test"
        case .library(.static):
            return "\(name)-\(config).a"
        case .library(.automatic):
            fatalError()
        case .executable:
            return "\(name)-\(config).exe"
        }
    }

    public func getCommandName(config: String) -> String {
        return "C." + getLLBuildTargetName(config: config)
    }
}
