package cli

// topLevel are the commands without a noun.
var topLevel = []command{
	loginCommand(),
	logoutCommand(),
	whoamiCommand(),
	passwordCommand(),
	findCommand(),
	codeCommand(),
	completionCommand(),
}

// groups are the nouns and their verbs.
var groups = []group{
	itemGroup(),
	stockGroup(),
	locationGroup(),
	classGroup(),
	classAttributeGroup(),
	classChoiceGroup(),
	modelGroup(),
	fileGroup(),
	accountGroup(),
	sessionsGroup(),
	profileGroup(),
}
