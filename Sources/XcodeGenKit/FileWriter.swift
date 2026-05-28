import Foundation
import PathKit
import ProjectSpec
import XcodeProj

public class FileWriter {

    let project: Project

    public init(project: Project) {
        self.project = project
    }

    public func writeXcodeProject(_ xcodeProject: XcodeProj, to projectPath: Path? = nil) throws {
        let projectPath = projectPath ?? project.defaultProjectPath
        let tempPath = try Path.processUniqueTemporary() + "XcodeGen"
        try? tempPath.delete()
        if projectPath.exists {
            try projectPath.copy(tempPath)
        }
        try xcodeProject.write(path: tempPath, override: true)
        try patchLocalPackageProductDependencyReferences(
            in: tempPath + "project.pbxproj",
            generatedProjectPath: projectPath
        )
        try? projectPath.delete()
        try tempPath.copy(projectPath)
        try? tempPath.delete()
    }

    public func writePlists() throws {

        let infoPlistGenerator = InfoPlistGenerator()
        for target in project.targets {
            // write Info.plist
            if let plist = target.info {
                let properties = infoPlistGenerator.generateProperties(for: target).merged(plist.properties)
                try writePlist(properties, path: plist.path)
            }

            // write entitlements
            if let plist = target.entitlements {
                try writePlist(plist.properties, path: plist.path)
            }
        }
    }

    private func writePlist(_ plist: [String: Any], path: String) throws {
        let path = project.basePath + path
        if path.exists, let data: Data = try? path.read(),
            let existingPlist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any], NSDictionary(dictionary: plist).isEqual(to: existingPlist) {
            // file is the same
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try? path.delete()
        try path.parent().mkpath()
        try path.write(data)
    }

    private func patchLocalPackageProductDependencyReferences(
        in pbxprojPath: Path,
        generatedProjectPath: Path
    ) throws {
        let localPackageAbsolutePathsByProductName = localPackageAbsolutePathsByProductName()
        guard !localPackageAbsolutePathsByProductName.isEmpty else { return }

        let pbxproj: String = try pbxprojPath.read()
        let lines = pbxproj.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let localPackageReferencesByPath = parseLocalPackageReferencesByPath(from: lines)
        guard !localPackageReferencesByPath.isEmpty else { return }

        let xcodeprojDirectory = pbxprojPath.parent()
        let generatedProjectDirectory = generatedProjectPath.parent()
        let projectBasePath = project.basePath.absolute().normalize()
        var productToLocalPackageReference: [String: String] = [:]
        for (productName, absolutePackagePath) in localPackageAbsolutePathsByProductName {
            let relativeToProjectPath = (try? absolutePackagePath.relativePath(from: projectBasePath).string)
            let relativeToGeneratedProjectPath = (try? absolutePackagePath.relativePath(from: generatedProjectDirectory).string)
            let relativeToXcodeprojPath = (try? absolutePackagePath.relativePath(from: xcodeprojDirectory).string)

            let pathCandidates = [
                relativeToProjectPath,
                relativeToProjectPath.map { Path($0).normalize().string },
                relativeToGeneratedProjectPath,
                relativeToGeneratedProjectPath.map { Path($0).normalize().string },
                relativeToXcodeprojPath,
                relativeToXcodeprojPath.map { Path($0).normalize().string },
                absolutePackagePath.string,
                absolutePackagePath.normalize().string,
            ].compactMap { $0 }

            if let localReference = pathCandidates.lazy.compactMap({ localPackageReferencesByPath[$0] }).first {
                productToLocalPackageReference[productName] = localReference
            }
        }
        guard !productToLocalPackageReference.isEmpty else { return }

        var patchedLines: [String] = []
        patchedLines.reserveCapacity(lines.count)

        var inProductDependencySection = false
        var productDependencyBlock: [String] = []
        var didPatch = false

        for line in lines {
            if line.contains("/* Begin XCSwiftPackageProductDependency section */") {
                inProductDependencySection = true
                patchedLines.append(line)
                continue
            }

            if line.contains("/* End XCSwiftPackageProductDependency section */") {
                inProductDependencySection = false
                if !productDependencyBlock.isEmpty {
                    let patchedBlock = patchProductDependencyBlock(
                        productDependencyBlock,
                        productToLocalPackageReference: productToLocalPackageReference
                    )
                    didPatch = didPatch || patchedBlock != productDependencyBlock
                    patchedLines.append(contentsOf: patchedBlock)
                    productDependencyBlock.removeAll(keepingCapacity: true)
                }
                patchedLines.append(line)
                continue
            }

            guard inProductDependencySection else {
                patchedLines.append(line)
                continue
            }

            if !productDependencyBlock.isEmpty || isPBXObjectStart(line) {
                productDependencyBlock.append(line)
                if line.trimmingCharacters(in: .whitespacesAndNewlines) == "};" {
                    let patchedBlock = patchProductDependencyBlock(
                        productDependencyBlock,
                        productToLocalPackageReference: productToLocalPackageReference
                    )
                    didPatch = didPatch || patchedBlock != productDependencyBlock
                    patchedLines.append(contentsOf: patchedBlock)
                    productDependencyBlock.removeAll(keepingCapacity: true)
                }
            } else {
                patchedLines.append(line)
            }
        }

        if didPatch {
            try pbxprojPath.write(patchedLines.joined(separator: "\n"))
        }
    }

    private func localPackageAbsolutePathsByProductName() -> [String: Path] {
        var localPackageAbsolutePathsByName: [String: Path] = [:]
        for (packageName, package) in project.packages {
            if case let .local(path, _, excludeFromProject) = package, !excludeFromProject {
                localPackageAbsolutePathsByName[packageName] = (project.basePath + Path(path).normalize()).absolute().normalize()
            }
        }

        guard !localPackageAbsolutePathsByName.isEmpty else { return [:] }

        var packagePathsByProductName: [String: Set<Path>] = [:]

        func addProduct(_ productName: String, packagePath: Path) {
            packagePathsByProductName[productName, default: []].insert(packagePath)
        }

        for target in project.targets {
            for dependency in target.dependencies {
                guard case let .package(products) = dependency.type,
                    let packagePath = localPackageAbsolutePathsByName[dependency.reference] else {
                    continue
                }

                if products.isEmpty {
                    addProduct(dependency.reference, packagePath: packagePath)
                } else {
                    for product in products {
                        addProduct(product, packagePath: packagePath)
                    }
                }
            }

            for plugin in target.buildToolPlugins {
                guard let packagePath = localPackageAbsolutePathsByName[plugin.package] else {
                    continue
                }
                addProduct("plugin:\(plugin.plugin)", packagePath: packagePath)
            }
        }

        for target in project.aggregateTargets {
            for plugin in target.buildToolPlugins {
                guard let packagePath = localPackageAbsolutePathsByName[plugin.package] else {
                    continue
                }
                addProduct("plugin:\(plugin.plugin)", packagePath: packagePath)
            }
        }

        return packagePathsByProductName.compactMapValues { packagePaths in
            guard packagePaths.count == 1 else { return nil }
            return packagePaths.first
        }
    }

    private func parseLocalPackageReferencesByPath(from lines: [String]) -> [String: String] {
        var localPackageReferencesByPath: [String: String] = [:]
        var inLocalPackageReferenceSection = false
        var currentReference: String?
        var currentPath: String?

        for line in lines {
            if line.contains("/* Begin XCLocalSwiftPackageReference section */") {
                inLocalPackageReferenceSection = true
                continue
            }

            if line.contains("/* End XCLocalSwiftPackageReference section */") {
                inLocalPackageReferenceSection = false
                currentReference = nil
                currentPath = nil
                continue
            }

            guard inLocalPackageReferenceSection else { continue }

            if let reference = pbxObjectReference(from: line, marker: "XCLocalSwiftPackageReference") {
                currentReference = reference
                currentPath = nil
                continue
            }

            if let relativePath = pbxAssignedValue(for: "relativePath", in: line) {
                currentPath = relativePath
                continue
            }

            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "};" {
                if let path = currentPath, let reference = currentReference {
                    localPackageReferencesByPath[path] = reference
                }
                currentReference = nil
                currentPath = nil
            }
        }

        return localPackageReferencesByPath
    }

    private func patchProductDependencyBlock(
        _ block: [String],
        productToLocalPackageReference: [String: String]
    ) -> [String] {
        guard !block.isEmpty else { return block }
        guard !block.contains(where: { $0.contains("package = ") }) else { return block }

        guard let productNameLine = block.first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("productName = ") }),
            let productName = pbxAssignedValue(for: "productName", in: productNameLine),
            let localPackageReference = productToLocalPackageReference[productName] else {
            return block
        }

        guard let isaIndex = block.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "isa = XCSwiftPackageProductDependency;"
        }) else {
            return block
        }

        let indentation = String(block[isaIndex].prefix(while: { $0 == " " || $0 == "\t" }))
        var patchedBlock = block
        patchedBlock.insert("\(indentation)package = \(localPackageReference);", at: isaIndex + 1)
        return patchedBlock
    }

    private func isPBXObjectStart(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("= {")
    }

    private func pbxObjectReference(from line: String, marker: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "= {", options: .backwards), trimmed.contains(marker) else {
            return nil
        }
        return String(trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func pbxAssignedValue(for key: String, in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "\(key) = "
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(";") else { return nil }

        let valueStart = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        let valueEnd = trimmed.index(before: trimmed.endIndex)
        let rawValue = String(trimmed[valueStart..<valueEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

        if rawValue.hasPrefix("\""), rawValue.hasSuffix("\""), rawValue.count >= 2 {
            let innerStart = rawValue.index(after: rawValue.startIndex)
            let innerEnd = rawValue.index(before: rawValue.endIndex)
            return String(rawValue[innerStart..<innerEnd]).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return rawValue
    }
}
