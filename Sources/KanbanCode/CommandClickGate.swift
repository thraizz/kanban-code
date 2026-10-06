import Foundation

/// Decides which mouse events of a cmd+click on a link the terminal keeps
/// from the program running in it. The program gets the whole click or none
/// of it: a press without its release leaves the program waiting for one,
/// and a program that takes the next buttonless motion as that release (rush
/// does) acts on the click a second time when the pointer comes back, which
/// opens the link again after the browser hands the focus back.
struct CommandClickGate {
    enum Outcome: Equatable {
        /// The event goes on to the terminal and the program in it.
        case pass
        /// The event stops here.
        case consume
        /// The event stops here and the link opens.
        case open(String)
    }

    /// The link a cmd+press landed on, until the button comes up.
    private(set) var pressedLink: String?

    /// A press with cmd held on a link is kept, so the program never sees
    /// the click start.
    mutating func mouseDown(command: Bool, link: String?) -> Outcome {
        pressedLink = nil
        guard command, let link else { return .pass }
        pressedLink = link
        return .consume
    }

    /// A drag that began as a kept press is kept too.
    func mouseDragged() -> Outcome {
        pressedLink == nil ? .pass : .consume
    }

    /// The release of a kept press is kept, and opens the link when it comes
    /// up on the one it went down on. A release whose press the program saw
    /// goes to the program.
    mutating func mouseUp(link: String?) -> Outcome {
        guard let pressed = pressedLink else { return .pass }
        pressedLink = nil
        return link == pressed ? .open(pressed) : .consume
    }
}
