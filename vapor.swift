#!/usr/bin/env swift

#if os(OSX)
    import Darwin
#else
    import Glibc
#endif

import Foundation

// MARK: Utilities

@noreturn func fail(_ message: String) {
    print("Error: \(message)")
    exit(1)
}

enum Error: ErrorProtocol {
    case System(Int32)
    case Cancelled
    var code: Int32 {
        switch self {
        case .Cancelled:
            return 2
        case .System(let code):
            return code
        }
    }
}

func run(_ command: String) throws {
    let result = system(command)

    if result == 2 {
        throw Error.Cancelled
    } else if result != 0 {
        throw Error.System(result)
    }
}

func passes(_ command: String) -> Bool {
    return system(command) == 0
}

func getInput() -> String {
    return readLine(strippingNewline: true) ?? ""
}

func commandExists(_ command: String) -> Bool {
    return system("hash \(command) 2>/dev/null") == 0
}

func gitHistoryIsClean() -> Bool {
    return system("test -z \"$(git status --porcelain)\" || exit 1") == 0
}

func readPackageSwiftFile() -> String {
    let file = "./Package.swift"
    do {
        return try String(contentsOfFile: file)
    } catch {
        print()
        print("Unable to find Package.swift")
        print("Make sure you've run `vapor new` or setup your Swift project manually")
        fail("")
    }
}

func extractPackageName(from packageFile: String) -> String {
    let packageName = packageFile
        .components(separatedBy: "\n")
        .lazy
        .map { $0.trimmedSpaces() }
        .filter { $0.hasPrefix("name") }
        .first?
        .components(separatedBy: "\"")
        .lazy
        .filter { !$0.hasPrefix("name") }
        .first

    guard let name = packageName else {
        fail("Unable to extract package name")
    }

    return name
}

func getPackageName() -> String {
    let packageFile = readPackageSwiftFile()
    let packageName = extractPackageName(from: packageFile)
    return packageName
}

extension String {
    func trimmedSpaces() -> String {
        // while characters
        var mutable = self
        while let next = mutable.characters.first where next == " " {
            mutable.remove(at: mutable.startIndex)
        }
        while let next = mutable.characters.last where next == " " {
            mutable.remove(at: mutable.index(before: mutable.endIndex))
        }
        return mutable
    }

#if os(Linux)
    func hasPrefix(_ str: String) -> Bool {
        let strGen = str.characters.makeIterator()
        let selfGen = self.characters.makeIterator()
        let seq = zip(strGen, selfGen)
        for (lhs, rhs) in seq where lhs != rhs {
                return false
        }
        return true
    }

    func hasSuffix(_ str: String) -> Bool {
        let strGen = str.characters.reversed().makeIterator()
        let selfGen = self.characters.reversed().makeIterator()
        let seq = zip(strGen, selfGen)
        for (lhs, rhs) in seq where lhs != rhs {
                return false
        }
        return true
    }
#endif
}

extension Sequence where Iterator.Element == String {
    func valueFor(argument name: String) -> String? {
        for argument in self where argument.hasPrefix("--\(name)=") {
            return argument.characters.split(separator: "=").last.flatMap(String.init)
        }
        return nil
    }
}

extension Array where Element: Equatable {
    mutating func remove(_ element: Element) {
        self = self.filter { $0 != element }
    }

    mutating func remove(matching: (Element) -> Bool) {
        self = self.filter { !matching($0) }
    }
}

// MARK: Command

protocol Command {
    static var id: String { get }
    static var help: [String] { get }

    static var dependencies: [String] { get }
    static func execute(with args: [String], in directory: String)
}

extension Command {
    static var dependencies: [String] { return [] }
    static var help: [String] { return [] }
}

extension Command {
  static var description: String {
    guard help.count > 0 else {
      return "  \(id):\n"
    }
    
    return "  \(id):\n"
      + help
      .map { "    \($0)"}
      .joined(separator: "\n")
      + "\n"
  }
}

extension Command {
    static func assertDependenciesSatisfied() {
        for dependency in dependencies where !commandExists(dependency) {
            fail("\(id) requires \(dependency)")
        }
    }
}

// MARK: Tree

var commands: [Command.Type] = []

func getCommand(id: String) -> Command.Type? {
    return commands
        .lazy
        .filter { $0.id == id }
        .first
}

// MARK: Help

struct Help: Command {
    static let id = "help"
    static func execute(with args: [String], in directory: String) {
        print("Usage: \(directory) [\(commands.map({ $0.id }).joined(separator: "|"))]")

        var help = "Available Commands:\n\n"
        help += commands
            .map { cmd in cmd.description }//"  \(cmd.id):\n\(cmd.description)\n"}
            .joined(separator: "\n")
        help += "\n"
        print(help)

        print("Community:")
        print("  Join our Slack if you have questions,")
        print("  need help, or want to contribute.")
        print("  http://slack.qutheory.io")
    }
}

commands.append(Help)

// MARK: Clean

struct Clean: Command {
    static let id = "clean"
    static func execute(with args: [String], in directory: String) {
        guard args.isEmpty else {
            fail("\(id) doesn't take any additional parameters")
        }

        do {
            try run("rm -rf Packages .build")
            print("Cleaned.")
        } catch {
            fail("Could not clean.")
        }
    }
}

commands.append(Clean)

// MARK: Build

struct Build: Command {
    static let id = "build"
    static func execute(with args: [String], in directory: String) {
        do {
            try run("swift build --fetch")
        } catch Error.Cancelled {
            fail("Fetch cancelled")
        } catch {
            fail("Could not fetch dependencies.")
        }

        do {
            try run("rm -rf Packages/Sources/Vapor-*/Development")
            try run("rm -rf Packages/Sources/Vapor-*/Performance")
            try run("rm -rf Packages/Sources/Vapor-*/Generator")
        } catch {
            print("Failed to remove extra schemes")
        }

        var flags = args
        if args.contains("--release") {
            flags = flags.filter { $0 != "--release" }
            flags.append("-c release")
        }
        do {
            let buildFlags = flags.joined(separator: " ")
            try run("swift build \(buildFlags)")
        } catch Error.Cancelled {
            fail("Build cancelled.")
        } catch {
            print()
            print("Make sure you are running Apple Swift version 3.0.")
            print("Vapor only supports the latest snapshot.")
            print("Run swift --version to check your version.")

            fail("Could not build project.")
        }
    }
}

extension Build {
  static var help: [String] {
    return [
      "build <module-name>",
      "Builds source files and links Vapor libs.",
      "Defaults to App/ folder structure."
    ]
  }
}

commands.append(Build)

// MARK: Run

struct Run: Command {
    static let id = "run"
    static func execute(with args: [String], in directory: String) {
        print("Running...")
        do {
            var parameters = args
            let name = args.valueFor(argument: "name") ?? "App"
            parameters.remove { $0.hasPrefix("--name") }

            let folder = args.contains("--release") ? "release" : "debug"
            parameters.remove("--release")

            // All remaining arguments are passed on to app
            let passthroughArgs = args.joined(separator: " ")
            // TODO: Check that file exists
            try run(".build/\(folder)/\(name) \(passthroughArgs)")
        } catch Error.Cancelled {
            fail("Run cancelled.")
        } catch {
            fail("Could not run project.")
        }
    }
}

extension Run {
  static var help: [String] {
    return [
      "runs executable built by vapor build.",
      "use --release for release configuration."
    ]
  }
}

commands.append(Run)

// MARK: New

struct New: Command {
    static let id = "new"

    static func execute(with args: [String], in directory: String) {
        guard let name = args.first else {
            print("Usage: \(directory) \(id) <project-name>")
            fail("Invalid number of arguments.")
        }

        let verbose = args.contains("--verbose")
        let curlArgs = verbose ? "" : "-s"
        let tarArgs = verbose ? "v" : ""

        do {
            let escapedName = "\"\(name)\"" // FIX: Doesn’t support names with quotes
            try run("mkdir \(escapedName)")

            try run("curl -L \(curlArgs) https://github.com/qutheory/vapor-example/archive/master.tar.gz -o \(escapedName)/vapor-example.tar.gz")
            try run("tar -\(tarArgs)xzf \(escapedName)/vapor-example.tar.gz --strip-components=1 --directory \(escapedName)")
            try run("rm \(escapedName)/vapor-example.tar.gz")
            #if os(OSX)
                try run("cd \(escapedName) && swift build -X")
            #endif

            if commandExists("git") {
                print("Initializing git repository if necessary")
                system("git init \(escapedName)")
                system("cd \(escapedName) && git add . && git commit -m \"initial vapor project setup\"")
                print()
            }

            print()
            print("Project \"\(name)\" has been created.")
            print("Type `cd \(name)` to enter project directory")
            print("Enjoy!")
            print()
            system("open \(escapedName)/*.xcodeproj")
        } catch {
            fail("Could not clone repository")
        }
    }
}

extension New {
  static var help: [String] {
    return [
      "new <project-name>",
      "Clones the Vapor Example to a given",
      "folder name and initializes an empty",
      "Git repository inside it."
    ]
  }
}

commands.append(New)

// MARK: Bootstrap

struct Bootstrap: Command {
    static let id = "bootstrap"

    static func execute(with args: [String], in directory: String) {
        let binary: String = {
            if let p = args.first {
                return p.hasSuffix("/") ? p : p + "/"
            } else {
                return "./"
            }
        }() + "vapor"

        let src = Process.arguments[0]
        let cmd = "env SDKROOT=$(xcrun -show-sdk-path -sdk macosx) swiftc \(src) -o \(binary)"
        do {
            try run(cmd)
        } catch {
            fail("Could not compile \(src), try running the following command in order to debug this issue:\n\(cmd)")
        }
    }

    static var help: [String] {
        return [
            "bootstrap <directory>",
            "Compiles and installs the vapor binary in the",
            "specified location (defaults to current directory).",
            "Only supported on Mac OSX for the moment."
        ]
    }
}

commands.append(Bootstrap)

// MARK: SelfUpdate

struct SelfUpdate: Command {
    static let id = "self-update"

    static func execute(with args: [String], in directory: String) {
        let name = "vapor-cli.tmp"
        let quiet = args.contains("--verbose") ? "" : "-s"

        do {
            print("Downloading...")
            try run("curl -L \(quiet) cli.qutheory.io -o \(name)")
        } catch {
            print("Could not download Vapor CLI.")
            return
        }

        do {
            try run("chmod +x \(name)")
            try run("mv \(name) \(directory)")
        } catch {
            print("Could not move Vapor CLI to install location.")
            print("Trying with 'sudo'.")
            do {
                try run("sudo mv \(name) \(directory)")
            } catch {
                fail("Could not move Vapor CLI to install location, giving up.")
            }
        }

        print("Vapor CLI updated.")
    }
}

extension SelfUpdate {
  static var help: [String] {
    return [
      "Downloads the latest version of",
      "the Vapor command line interface."
    ]
  }
}

commands.append(SelfUpdate)

// MARK: Xcode

#if os(OSX)

struct Xcode: Command {
    static let id = "xcode"

    static func execute(with args: [String], in directory: String) {
        print("Generating Xcode Project...")

        do {
            try run("swift build --generate-xcodeproj")
        } catch {
            print("Could not generate Xcode Project.")
            return
        }

        print("Opening Xcode...")

        do {
            try run("open *.xcodeproj")
        } catch {
            fail("Could not open Xcode Project.")
        }
    }
}

extension Xcode {
  static var help: [String] {
    return [
      "Generates and opens an Xcode Project."
    ]
  }
}

commands.append(Xcode)

#endif

// MARK: Heroku

protocol Subcommand: Command {}

struct Heroku: Command {
    static let id = "heroku"

    static var dependencies = ["git", "heroku"]

    static var subcommands: [Subcommand.Type] = []

    static var supportedCommands: String {
        return subcommands.map { $0.id } .joined(separator: "|")
    }

    static func subcommand(forId id: String) -> Subcommand.Type? {
        return subcommands
            .lazy
            .filter { $0.id == id }
            .first
    }

    static func execute(with args: [String], in directory: String) {
        var iterator = args.makeIterator()
        guard let subcommand = iterator.next().flatMap(subcommand(forId:)) else {
            fail("heroku subcommand not found. supported: \(supportedCommands)")
        }

        let passthroughArgs = Array(iterator)
        subcommand.execute(with: passthroughArgs, in: directory)
    }
}

extension Heroku {
  static var help: [String] {
    return [
      "Configures a new heroku project"
    ]
  }
}

extension Heroku {
    struct Init: Subcommand {
        static let id = "init"
        static func execute(with args: [String], in directory: String) {
            guard args.isEmpty else { fail("heroku init takes no args") }

            if !gitHistoryIsClean() {
                print("Found Uncommitted Changes")
                print("Setting up heroku requires adding a commit to the repository")
                print("Please commit your current changes before setting up heroku")
                fail("")
            }

            let packageName = getPackageName()
            print("Setting up Heroku for \(packageName) ...")
            print()

            let herokuIsAlreadyInitialized = passes("git remote get-url heroku")
            if herokuIsAlreadyInitialized {
                print("Found existing heroku app")
                print()
            } else {
                print("Custom Heroku App Name? (return to let Heroku create)")
                let herokuAppName = getInput()
                do {
                    try run("heroku create \(herokuAppName)")
                } catch {
                    fail("unable to create heroku app")
                }
            }

            print("Custom Buildpack? (return to use default)")
            var buildpack = ""
            if let input = readLine(strippingNewline: true) where !buildpack.isEmpty {
                buildpack = input
            } else {
                buildpack = "https://github.com/kylef/heroku-buildpack-swift"
            }

            do {
                try run("heroku buildpacks:set \(buildpack)")
                print("Using buildpack: \(buildpack)")
                print()
            } catch let e as Error where e.code == 256 {
                print()
            } catch {
                fail("unable to set buildpack: \(buildpack)")
            }

            print("Creating Procfile ...")
            // TODO: Discuss
            // Should it be
            //    let procContents = "web: \(packageName) --port=\\$PORT"
            // It causes errors like that and forces `App` as process.
            // Forces us to use Vapor CLI
            // Maybe that's something we want
            let procContents = "web: App --port=\\$PORT"
            do {
                // Overwrites existing Procfile
                try run("echo \"\(procContents)\" > ./Procfile")
            } catch {
                fail("Unable to make Procfile")
            }

            print()
            print("Would you like to push to heroku now? (y/n)")
            let input = getInput().lowercased()
            if input.hasPrefix("n") {
                print("\n\n")
                print("Make sure to push your changes to heroku using:")
                print("\t'git push heroku master'")
                print("You may need to scale up dynos")
                print("\t'heroku ps:scale web=1'")
                exit(0)
            }

            print()
            print("Pushing to heroku ... this could take a while")
            print()

            system("git add .")
            system("git commit -m \"setting up heroku\"")
            system("git push heroku master")

            print("spinning up dynos ...")
            do {
                try run("heroku ps:scale web=1")
            } catch {
                fail("unable to spin up dynos")
            }
        }
    }
}

Heroku.subcommands.append(Heroku.Init.self)
commands.append(Heroku)

// MARK: CLI

var iterator = Process.arguments.makeIterator()

guard let directory = iterator.next() else {
    fail("no directory")
}
guard let commandId = iterator.next() else {
    print("Usage: \(directory) [\(commands.map({ $0.id }).joined(separator: "|"))]")
    fail("no command")
}
guard let command = getCommand(id: commandId) else {
    fail("command \(commandId) doesn't exist")
}

command.assertDependenciesSatisfied()

let arguments = Array(iterator)
command.execute(with: arguments, in: directory)
exit(0)
