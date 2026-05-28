import Foundation
import ProjectSpec

extension Project {

    public var xcodeVersion: String {
        XCodeVersion.parse(options.xcodeVersion ?? "14.3")
    }

    public var projectFormat: ProjectFormat {
        if let explicitProjectFormat = options.projectFormat.flatMap(ProjectFormat.init(rawValue:)) {
            return explicitProjectFormat
        }

        if let xcodeVersion = options.xcodeVersion,
           let inferredProjectFormat = ProjectFormat(fromXcodeVersion: xcodeVersion) {
            return inferredProjectFormat
        }

        return .default
    }

    var schemeVersion: String {
        "1.7"
    }

    var compatibilityVersion: String? {
        projectFormat.compatibilityVersion
    }

    var objectVersion: UInt {
        projectFormat.objectVersion
    }

    var preferredProjectObjectVersion: UInt? {
        projectFormat.preferredProjectObjectVersion
    }

    var minimizedProjectReferenceProxies: Int {
        1
    }
}

private extension ProjectFormat {
    init?(fromXcodeVersion version: String) {
        let normalizedVersion = XCodeVersion.parse(version)
        guard let numericVersion = Int(normalizedVersion) else {
            return nil
        }

        switch numericVersion {
        case 2630...:
            self = .xcode26_3
        case 1630...:
            self = .xcode16_3
        case 1600...:
            self = .xcode16_0
        case 1530...:
            self = .xcode15_3
        case 1500...:
            self = .xcode15_0
        case 1400...:
            self = .xcode14_0
        default:
            return nil
        }
    }
}

public struct XCodeVersion {

    public static func parse(_ version: String) -> String {
        if version.contains(".") {
            let parts = version.split(separator: ".").map(String.init)
            var string = ""
            let major = parts[0]
            if major.count == 1 {
                string = "0\(major)"
            } else {
                string = major
            }

            let minor = parts[1]
            string += minor

            if parts.count > 2 {
                let patch = parts[2]
                string += patch
            } else {
                string += "0"
            }
            return string
        } else if version.count == 2 {
            return "\(version)00"
        } else if version.count == 1 {
            return "0\(version)00"
        } else {
            return version
        }
    }
}
