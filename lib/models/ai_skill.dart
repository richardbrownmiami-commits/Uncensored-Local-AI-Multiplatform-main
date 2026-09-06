class AiSkill {
  final String id;
  final String name;
  final String description;
  final String systemPrompt;

  const AiSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.systemPrompt,
  });

  static const builtIns = <AiSkill>[
    AiSkill(
      id: 'general',
      name: 'General Assistant',
      description: 'Balanced general-purpose local assistant.',
      systemPrompt: 'Be helpful, direct, accurate, and concise. Follow the user request and ask for clarification only when necessary.',
    ),
    AiSkill(
      id: 'coding',
      name: 'Coding',
      description: 'Software development and debugging skill.',
      systemPrompt: 'Act as a senior software engineer. Produce practical, testable code. Explain important trade-offs briefly and preserve existing project architecture unless a change is required.',
    ),
    AiSkill(
      id: 'writer',
      name: 'Writer',
      description: 'Writing, rewriting, editing, and drafting.',
      systemPrompt: 'Act as an expert writer and editor. Match the requested tone, preserve important meaning, and return polished usable text.',
    ),
    AiSkill(
      id: 'research',
      name: 'Research',
      description: 'Structured analysis and evidence-oriented reasoning.',
      systemPrompt: 'Act as a research assistant. Separate facts from assumptions, organize findings clearly, and identify uncertainty when evidence is incomplete.',
    ),
    AiSkill(
      id: 'custom',
      name: 'Custom',
      description: 'Use the exact instructions entered in the prompt window.',
      systemPrompt: '',
    ),
  ];
}
