//===----------------------------------------------------------*- swift -*-===//
//
// This source file is part of the Swift Argument Parser open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

internal struct HelpGenerator {
  static var helpIndent = 2
  static var labelColumnWidth = 26
  static var systemScreenWidth: Int {
    _screenWidthOverride ?? _terminalSize().width
  }
  
  internal static var _screenWidthOverride: Int? = nil
  
  struct Usage {
    var components: [String]
    
    func rendered(screenWidth: Int) -> String {
      components
        .joined(separator: "\n")
    }
  }
  
  struct Section {
    struct Element: Hashable {
      var label: String
      var abstract: String = ""
      var discussion: String = ""
      
      var paddedLabel: String {
        String(repeating: " ", count: HelpGenerator.helpIndent) + label
      }
      
      func rendered(screenWidth: Int) -> String {
        let paddedLabel = self.paddedLabel
        let wrappedAbstract = self.abstract
          .wrapped(to: screenWidth, wrappingIndent: HelpGenerator.labelColumnWidth)
        let wrappedDiscussion = self.discussion.isEmpty
          ? ""
          : self.discussion.wrapped(to: screenWidth, wrappingIndent: HelpGenerator.helpIndent * 4) + "\n"
        let renderedAbstract: String = {
          guard !abstract.isEmpty else { return "" }
          if paddedLabel.count < HelpGenerator.labelColumnWidth {
            // Render after padded label.
            return String(wrappedAbstract.dropFirst(paddedLabel.count))
          } else {
            // Render in a new line.
            return "\n" + wrappedAbstract
          }
        }()
        return paddedLabel
          + renderedAbstract + "\n"
          + wrappedDiscussion
      }
    }
    
    enum Header: CustomStringConvertible, Equatable {
      case positionalArguments
      case subcommands
      case options
      
      var description: String {
        switch self {
        case .positionalArguments:
          return "Arguments"
        case .subcommands:
          return "Subcommands"
        case .options:
          return "Options"
        }
      }
    }
    
    var header: Header
    var elements: [Element]
    var discussion: String = ""
    var isSubcommands: Bool = false
    
    func rendered(screenWidth: Int) -> String {
      guard !elements.isEmpty else { return "" }
      
      let renderedElements = elements.map { $0.rendered(screenWidth: screenWidth) }.joined()
      return "\(String(describing: header).uppercased()):\n"
        + renderedElements
    }
  }
  
  struct DiscussionSection {
    var title: String = ""
    var content: String
  }
  
  var commandStack: [ParsableCommand.Type]
  var abstract: String
  var usage: Usage
  var sections: [Section]
  var discussionSections: [DiscussionSection]
  
  init(commandStack: [ParsableCommand.Type]) {
    guard let currentCommand = commandStack.last else {
      fatalError()
    }
    
    let currentArgSet = ArgumentSet(currentCommand)
    self.commandStack = commandStack

    // Build the tool name and subcommand name from the command configuration
    var toolName = commandStack.map { $0._commandName }.joined(separator: " ")
    if let superName = commandStack.first!.configuration._superCommandName {
      toolName = "\(superName) \(toolName)"
    }

    var usageString = UsageGenerator(toolName: toolName, definition: [currentArgSet]).synopsis
    if !currentCommand.configuration.subcommands.isEmpty {
      if usageString.last != " " { usageString += " " }
      usageString += "<subcommand>"
    }
    
    self.abstract = currentCommand.configuration.abstract
    if !currentCommand.configuration.discussion.isEmpty {
      if !self.abstract.isEmpty {
        self.abstract += "\n"
      }
      self.abstract += "\n\(currentCommand.configuration.discussion)"
    }
    
    self.usage = Usage(components: [usageString])
    self.sections = HelpGenerator.generateSections(commandStack: commandStack)
    self.discussionSections = []
  }
  
  init(_ type: ParsableArguments.Type) {
    self.init(commandStack: [type.asCommand])
  }

  static func generateSections(commandStack: [ParsableCommand.Type]) -> [Section] {
    guard !commandStack.isEmpty else { return [] }
    
    var positionalElements: [Section.Element] = []
    var optionElements: [Section.Element] = []

    /// Start with a full slice of the ArgumentSet so we can peel off one or
    /// more elements at a time.
    var args = commandStack.argumentsForHelp()[...]
    
    while let arg = args.popFirst() {
      guard arg.help.help?.shouldDisplay != false else { continue }
      
      let synopsis: String
      let description: String
      
      if arg.help.isComposite {
        // If this argument is composite, we have a group of arguments to
        // output together.
        let groupEnd = args.firstIndex(where: { $0.help.keys != arg.help.keys }) ?? args.endIndex
        let groupedArgs = [arg] + args[..<groupEnd]
        args = args[groupEnd...]
        
        synopsis = groupedArgs.compactMap { $0.synopsisForHelp }.joined(separator: "/")

        let defaultValue = arg.help.defaultValue.map { "(default: \($0))" } ?? ""
        let descriptionString = groupedArgs.lazy.compactMap({ $0.help.help?.abstract }).first
        description = [descriptionString, defaultValue]
          .compactMap { $0 }
          .joined(separator: " ")
      } else {
        synopsis = arg.synopsisForHelp ?? ""

        let defaultValue = arg.help.defaultValue.flatMap { $0.isEmpty ? nil : "(default: \($0))" }
        description = [arg.help.help?.abstract, defaultValue]
          .compactMap { $0 }
          .joined(separator: " ")
      }
      
      let element = Section.Element(label: synopsis, abstract: description, discussion: arg.help.help?.discussion ?? "")
      if case .positional = arg.kind {
        positionalElements.append(element)
      } else {
        optionElements.append(element)
      }
    }
    
    let configuration = commandStack.last!.configuration
    let subcommandElements: [Section.Element] =
      configuration.subcommands.compactMap { command in
        guard command.configuration.shouldDisplay else { return nil }
        var label = command._commandName
        if command == configuration.defaultSubcommand {
            label += " (default)"
        }
        return Section.Element(
          label: label,
          abstract: command.configuration.abstract)
    }
    
    return [
      Section(header: .positionalArguments, elements: positionalElements),
      Section(header: .options, elements: optionElements),
      Section(header: .subcommands, elements: subcommandElements),
    ]
  }
  
  func usageMessage(screenWidth: Int? = nil) -> String {
    let screenWidth = screenWidth ?? HelpGenerator.systemScreenWidth
    return "Usage: \(usage.rendered(screenWidth: screenWidth))"
  }
  
  var includesSubcommands: Bool {
    guard let subcommandSection = sections.first(where: { $0.header == .subcommands })
      else { return false }
    return !subcommandSection.elements.isEmpty
  }
  
  func rendered(screenWidth: Int? = nil) -> String {
    let screenWidth = screenWidth ?? HelpGenerator.systemScreenWidth
    let renderedSections = sections
      .map { $0.rendered(screenWidth: screenWidth) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    let renderedAbstract = abstract.isEmpty
      ? ""
      : "OVERVIEW: \(abstract)".wrapped(to: screenWidth) + "\n\n"
    
    var helpSubcommandMessage: String = ""
    if includesSubcommands {
      var names = commandStack.map { $0._commandName }
      if let superName = commandStack.first!.configuration._superCommandName {
        names.insert(superName, at: 0)
      }
      names.insert("help", at: 1)

      helpSubcommandMessage = """

          See '\(names.joined(separator: " ")) <subcommand>' for detailed help.
        """
    }
    
    return """
    \(renderedAbstract)\
    USAGE: \(usage.rendered(screenWidth: screenWidth))
    
    \(renderedSections)\(helpSubcommandMessage)
    """
  }
}

fileprivate extension CommandConfiguration {
  static var defaultHelpNames: NameSpecification { [.short, .long] }
}

fileprivate extension NameSpecification {
  func generateHelpNames() -> [Name] {
    return self.makeNames(InputKey(rawValue: "help")).sorted(by: >)
  }
}

internal extension BidirectionalCollection where Element == ParsableCommand.Type {
  func getHelpNames() -> [Name] {
    return self.last(where: { $0.configuration.helpNames != nil })
      .map { $0.configuration.helpNames!.generateHelpNames() }
      ?? CommandConfiguration.defaultHelpNames.generateHelpNames()
  }
  
  func getPrimaryHelpName() -> Name? {
    let names = getHelpNames()
    return names.first(where: { !$0.isShort }) ?? names.first
  }
  
  func versionArgumentDefintion() -> ArgumentDefinition? {
    guard contains(where: { !$0.configuration.version.isEmpty })
      else { return nil }
    return ArgumentDefinition(
      kind: .named([.long("version")]),
      help: .init(help: "Show the version.", key: InputKey(rawValue: "")),
      completion: .default,
      update: .nullary({ _, _, _ in })
    )
  }
  
  func helpArgumentDefinition() -> ArgumentDefinition? {
    let names = getHelpNames()
    guard !names.isEmpty else { return nil }
    return ArgumentDefinition(
      kind: .named(names),
      help: .init(help: "Show help information.", key: InputKey(rawValue: "")),
      completion: .default,
      update: .nullary({ _, _, _ in })
    )
  }
  
  /// Returns the ArgumentSet for the last command in this stack, including
  /// help and version flags, when appropriate.
  func argumentsForHelp() -> ArgumentSet {
    guard var arguments = self.last.map({ ArgumentSet($0, creatingHelp: true) })
      else { return ArgumentSet() }
    self.versionArgumentDefintion().map { arguments.append($0) }
    self.helpArgumentDefinition().map { arguments.append($0) }
    return arguments
  }
}

#if canImport(Glibc)
import Glibc
func ioctl(_ a: Int32, _ b: Int32, _ p: UnsafeMutableRawPointer) -> Int32 {
  ioctl(CInt(a), UInt(b), p)
}
#elseif canImport(Darwin)
import Darwin
#elseif canImport(CRT)
import CRT
import WinSDK
#endif

func _terminalSize() -> (width: Int, height: Int) {
#if os(Windows)
  var csbi: CONSOLE_SCREEN_BUFFER_INFO = CONSOLE_SCREEN_BUFFER_INFO()

  GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &csbi)
  return (width: Int(csbi.srWindow.Right - csbi.srWindow.Left) + 1,
          height: Int(csbi.srWindow.Bottom - csbi.srWindow.Top) + 1)
#else
  var w = winsize()
#if os(OpenBSD)
  // TIOCGWINSZ is a complex macro, so we need the flattened value.
  let tiocgwinsz = Int32(0x40087468)
  let err = ioctl(STDOUT_FILENO, tiocgwinsz, &w)
#else
  let err = ioctl(STDOUT_FILENO, TIOCGWINSZ, &w)
#endif
  let width = Int(w.ws_col)
  let height = Int(w.ws_row)
  guard err == 0 else { return (80, 25) }
  return (width: width > 0 ? width : 80,
          height: height > 0 ? height : 25)
#endif
}
