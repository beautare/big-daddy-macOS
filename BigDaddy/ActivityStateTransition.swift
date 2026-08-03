enum ActivityStateTransition: Equatable {
    case active
    case enteredIdle
    case resumed
    case idle

    static func resolve(previouslyIdle: Bool, isIdle: Bool) -> Self {
        if previouslyIdle && !isIdle { return .resumed }
        if isIdle { return previouslyIdle ? .idle : .enteredIdle }
        return .active
    }
}
