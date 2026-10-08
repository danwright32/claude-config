// Written by Claude Code 2.1.294.

declare module 'claude-code' {
  export type AgentCallRecord = {
      agentId: string;
      resolvedModel?: string;
  };

  export type AgentInfo = {
      id: string;
      teammateId?: string;
      description: string;
      type: string;
      status: AgentStatus;
      parentId?: string;
      spawnedBy?: string;
      name?: string;
  };

  export type AgentLoop = {
      agentId?: string;
  };

  export type AgentOfferInput = {
      agent: string;
      description: string;
      source: string;
      provider: Origin;
  };

  export type AgentOfferResult = {
      isOffered: boolean;
  };

  export type AgentSpawnArgs = Pick<AgentSpawnInput, 'prompt'> & Partial<Pick<AgentSpawnInput, 'description' | 'subagentType' | 'model' | 'name' | 'cwd'>>;

  export type AgentSpawnInput = {
      tool_use_id: string;
      prompt: string;
      description: string;
      subagentType: string;
      provider: Origin;
      model?: string;
      parentModel: string;
      parentAgentId?: string;
      permissionMode?: string;
      background: boolean;
      fork: boolean;
      isTeammate?: true;
      workflow?: {
          runId: string;
          agentIndex: number;
      };
      name?: string;
      cwd?: string;
  };

  export type AgentSpawnResult = {
      model: string;
      agentId?: string;
      teammateId?: string;
      deny?: undefined;
  } | {
      deny: string;
      model?: undefined;
      agentId?: undefined;
      teammateId?: undefined;
  };

  type AgentSpec = {
      name: string;
      description: string;
      prompt: string;
      tools?: readonly string[];
      disallowedTools?: readonly string[];
      model?: string;
      effort?: string | number;
      permissionMode?: string;
      mcpServers?: readonly (string | Record<string, unknown>)[];
      hooks?: Record<string, unknown>;
      maxTurns?: number;
      skills?: readonly string[];
      initialPrompt?: string;
      memory?: 'user' | 'project' | 'local';
      background?: true;
      omitClaudeMd?: true;
      isolation?: 'worktree' | 'remote';
  };

  export type AgentStatus = 'pending' | 'running' | 'waiting' | 'idle' | 'completed' | 'failed' | 'killed';

  export type AgentTeammateRecord = {
      status: 'teammate_spawned';
      agentId?: string;
      agent_id: string;
      teammate_id: string;
      name: string;
      team_name?: string;
      agent_type?: string;
      resolvedModel?: string;
      model?: string;
      prompt: string;
  };

  export type AnyEventHook = ($: EngineInterface, e: unknown, next: StarNext) => unknown;

  type AnyKeyOf<I> = I extends unknown ? keyof I : never;

  type ApiContentBlock = {
      type: string;
      [field: string]: unknown;
  };

  type ApiMessage = {
      role: 'user' | 'assistant';
      content: ApiContentBlock[];
  };

  export type Args<N extends EventName = EventName> = EventOf[N];

  export type AskOptions = {
      options?: readonly string[];
      header?: string;
      multiSelect?: true;
  };

  export type Atom<T> = {
      readonly ref: StateAddress;
      readonly initial: T;
      readonly shape?: string;
  };

  export type AtomFunction = {
      <P extends keyof PluginState & string, K extends keyof PluginState[P] & string>(ref: StateName<P, K> & Readonly<Pick<StateAddress, 'id'>>, initial: StateValue<P, K>): Atom<StateValue<P, K>>;
      <P extends keyof PluginState & string, K extends keyof PluginState[P] & string>(ref: StateName<P, K> & Readonly<Pick<StateAddress, 'id'>>, initial: ShapedValue<StateValue<P, K>>, options: AtomOptions): Atom<ShapedValue<StateValue<P, K>>>;
  };

  export type AtomOptions = {
      shape: string;
  };

  export type AttributionTextInput = {
      kind: AttributionTextKind;
      text: string;
  };

  export type AttributionTextKind = 'commit' | 'pr' | 'exemption' | 'remedy';

  export type AttributionTextResult = {
      text: string;
  };

  export type AudioClip = {
      asset: string;
      url?: undefined;
      base64?: undefined;
      mime?: undefined;
  } | {
      url: string;
      asset?: undefined;
      base64?: undefined;
      mime?: undefined;
  } | {
      base64: string;
      mime: string;
      asset?: undefined;
      url?: undefined;
  };

  type BackgroundTaskSummary = {
      id: string;
      type: string;
      status: string;
      description: string;
      command?: string;
      agent_type?: string;
      server?: string;
      tool?: string;
      name?: string;
  };

  type BaseHookInput = {
      session_id: string;
      transcript_path: string;
      cwd: string;
      prompt_id?: string;
      permission_mode?: string;
      agent_id?: string;
      agent_type?: string;
      effort?: {
          level: string;
      };
  };

  export type BoxHoverProps = {
      scope?: string;
      borderStyle?: string;
      borderColor?: Color;
      borderDimColor?: boolean;
      backgroundColor?: Color;
      display?: 'flex';
      top?: number;
      left?: number;
      right?: number;
      bottom?: number;
  };

  export type BoxProps = {
      key?: string;
      hover?: BoxHoverProps;
      position?: 'relative' | 'absolute';
      top?: number;
      left?: number;
      right?: number;
      bottom?: number;
      flexDirection?: 'row' | 'column' | 'row-reverse' | 'column-reverse';
      flexGrow?: number;
      flexShrink?: number;
      flexWrap?: 'nowrap' | 'wrap' | 'wrap-reverse';
      alignItems?: 'flex-start' | 'center' | 'flex-end' | 'stretch';
      alignSelf?: 'flex-start' | 'center' | 'flex-end' | 'auto';
      justifyContent?: 'flex-start' | 'center' | 'flex-end' | 'space-between' | 'space-around' | 'space-evenly';
      gap?: number;
      columnGap?: number;
      rowGap?: number;
      width?: number | string;
      height?: number | string;
      minWidth?: number | string;
      minHeight?: number | string;
      margin?: number;
      marginX?: number;
      marginY?: number;
      marginTop?: number;
      marginBottom?: number;
      marginLeft?: number;
      marginRight?: number;
      padding?: number;
      paddingX?: number;
      paddingY?: number;
      paddingTop?: number;
      paddingBottom?: number;
      paddingLeft?: number;
      paddingRight?: number;
      borderStyle?: string;
      borderColor?: Color;
      borderDimColor?: boolean;
      backgroundColor?: Color;
      overflow?: 'visible' | 'hidden';
      display?: 'flex' | 'none';
  };

  export type BuiltinToolCallInput = [BuiltinToolName] extends [never] ? BuiltinToolCallInputFallback : {
      [N in BuiltinToolName]: ToolInputOf<N, BuiltinToolInputs[N]>;
  }[BuiltinToolName];

  type BuiltinToolCallInputFallback = {
      tool: string;
      tool_use_id: string;
      [argument: string]: unknown;
  };

  export interface BuiltinToolInputs {
  }

  export type BuiltinToolName = keyof BuiltinToolInputs & string;

  export interface BuiltinToolResults {
  }

  export type ButtonProps = {
      key?: string;
      label?: string;
      hotkey?: string;
      action?: string;
      plain?: true;
      dimColor?: boolean;
      variant?: 'primary' | 'secondary';
      role?: 'dismiss';
      autoFocus?: true;
      hover?: TextHoverProps;
      onPress: (e: UiPressArgument) => void;
  };

  export type CatchHandler<F> = F extends ($: infer D, e: infer E, next: infer N) => infer R ? [R] extends [AsyncGenerator<unknown, unknown, unknown>] ? ($: D, e: E, next: N & Caught) => R : ($: D, e: E, next: N & Caught) => R | undefined | Promise<Awaited<R> | undefined> : never;

  export type Caught = {
      readonly error: HookFailure;
      readonly called: boolean;
  };

  export type Chunk<N extends StreamingEventName = StreamingEventName> = ChunkOf[N];

  export type ChunkOf = {
      'turn.step': TurnStepChunk;
      'process.spawn': ProcessSpawnChunk;
  };

  type ChunkRef = {
      ref?: number;
  };

  export type ClassicEventName = `classic.${ClassicHookEvent}`;

  export type ClassicEventOf = {
      [E in ClassicHookEvent as `classic.${E}`]: E extends 'PreToolUse' ? ToolCallEnvelope : ClassicHookInputs[E];
  };

  export type ClassicHookEvent = HookInput['hook_event_name'];

  export type ClassicHookInputs = {
      [I in HookInput as I['hook_event_name']]: I;
  };

  export type ClassicResult = {
      block?: string;
      preventContinuation?: true;
      stopReason?: string;
      additionalContext?: string[];
      sessionTitle?: string;
      suppressOriginalPrompt?: true;
      initialUserMessage?: string;
      watchPaths?: string[];
      reloadSkills?: true;
      permissionDecision?: 'allow' | 'deny' | 'ask';
      permissionDecisionReason?: string;
      decision?: PermissionRequestDecision;
      updatedToolOutput?: unknown;
      updatedMCPToolOutput?: unknown;
      retry?: true;
      displayContent?: string;
      worktreePath?: string;
  };

  export type ClassicResultFields = {
      UserPromptSubmit: 'additionalContext' | 'sessionTitle' | 'suppressOriginalPrompt';
      UserPromptExpansion: 'additionalContext' | 'suppressOriginalPrompt';
      SessionStart: 'additionalContext' | 'initialUserMessage' | 'sessionTitle' | 'watchPaths' | 'reloadSkills';
      Setup: 'additionalContext';
      PreModelSwitch: 'permissionDecision' | 'permissionDecisionReason';
      PostModelSwitch: 'additionalContext';
      SubagentStart: 'additionalContext';
      PostToolUse: 'additionalContext' | 'updatedToolOutput' | 'updatedMCPToolOutput';
      PostToolUseFailure: 'additionalContext';
      PostToolBatch: 'additionalContext';
      Stop: 'additionalContext';
      SubagentStop: 'additionalContext';
      PermissionDenied: 'retry';
      PermissionRequest: 'decision';
      MessageDisplay: 'displayContent';
      WorktreeCreate: 'worktreePath';
  };

  export type ClassicResultOf = {
      [E in ClassicHookEvent as `classic.${E}`]: E extends 'PreToolUse' ? PreToolUseResult : Pick<ClassicResult, 'block' | 'preventContinuation' | 'stopReason' | (E extends keyof ClassicResultFields ? ClassicResultFields[E] : never)>;
  };

  export type ClassifyOptions = {
      model?: string;
  };

  export type ClientElements = Omit<Elements['terminal'], 'Client' | 'Raster' | 'Image'>;

  export type ClientKeyEvent = {
      key: string;
      ctrl?: true;
      shift?: true;
      meta?: true;
  };

  export type ClientModule<P extends JsonValue = JsonValue, S = unknown> = (props: P, surface: ClientSurface<S>) => RenderElement;

  export type ClientPointerEvent = {
      type: ClientPointerType;
      x: number;
      y: number;
      fine?: {
          x: number;
          y: number;
      };
      button?: 'left' | 'middle' | 'right';
      shift?: true;
      alt?: true;
      ctrl?: true;
  };

  export type ClientPointerType = 'down' | 'move' | 'up' | 'enter' | 'leave';

  export type ClientProps = {
      key: string;
      module: string;
      props?: unknown;
      width?: number | string;
      height?: number | string;
      flexGrow?: number;
  };

  export type ClientSurface<S = unknown> = {
      readonly elements: ClientElements;
      readonly state: S | undefined;
      setState: (next: S) => void;
      readonly columns: number;
      readonly rows: number;
      every: (ms: number, fn: () => void) => () => void;
      onPointer: (fn: (event: ClientPointerEvent) => void) => () => void;
      onKey: (fn: (event: ClientKeyEvent) => void) => () => void;
      post: (data: JsonValue) => void;
  };

  type ClockWait = {
      ms: number;
  };

  export type CodeProps = {
      source: string;
      language?: string;
      path?: string;
      startLine?: number;
      format?: 'source' | 'diff';
      wrap?: 'wrap' | 'truncate-end';
  };

  export type Color = ThemeKey | (string & {});

  export type CommandDescribeInput = {
      command: string;
      description: string;
      argumentHint?: string;
      isHidden: boolean;
      immediate: boolean;
      provider: Origin;
  };

  export type CommandDescribeResult = Omit<CommandDescribeInput, 'command' | 'immediate' | 'provider'>;

  export type CommandInfo = {
      name: string;
      description: string;
      source: CommandSource;
      plugin?: string;
  };

  export type CommandPresentation = {
      isFullscreen: boolean;
      columns: number;
  };

  export type CommandRunArgs = Omit<CommandRunInput, 'origin' | 'args' | 'presentation'> & {
      args?: string;
  };

  export type CommandRunInput = {
      command: string;
      args: string;
      origin: PromptOrigin;
      presentation: CommandPresentation;
  };

  export type CommandRunResult = {
      text?: string;
      context?: readonly string[];
      exitCode?: number;
      ref?: number;
  };

  export type CommandSource = 'builtin' | 'plugin' | 'user' | 'mcp';

  export type CommandSpec = {
      name: string;
      description: string;
      argumentHint?: string;
      immediate?: true;
  };

  type ConfigChangeHookInput = BaseHookInput & {
      hook_event_name: 'ConfigChange';
      source: 'user_settings' | 'project_settings' | 'local_settings' | 'policy_settings' | 'skills';
      file_path?: string;
  };

  export type ConfigDescribeInput = {
      key: string;
      label: string;
      description?: string;
      isHidden: boolean;
      provider: Origin;
  };

  export type ConfigDescribeResult = Omit<ConfigDescribeInput, 'key' | 'provider'>;

  export type ConfigKind = 'boolean' | 'choice' | 'text' | 'number';

  export type ConfigOrigin = {
      kind: 'composer';
  } | {
      kind: 'bridge';
  } | {
      kind: 'plugin';
      name: string;
  };

  export type ConfigRow = {
      key: string;
      label: string;
      description?: string;
      kind: ConfigKind;
      value: ConfigValue;
      options?: readonly string[];
      provider: Origin;
      isLocked: boolean;
  };

  export type ConfigSetArgs = Pick<ConfigSetInput, 'key' | 'value'>;

  export type ConfigSetInput = {
      key: string;
      value: ConfigValue;
      previous: ConfigValue;
      provider: Origin;
      origin: ConfigOrigin;
  };

  export type ConfigSetResult = {
      value: ConfigValue;
      deny?: undefined;
  } | {
      deny: string;
      value?: undefined;
  };

  export type ConfigValue = boolean | string | number | readonly string[];

  export type ContextAgent = {
      agentType: string;
      source: string;
      tokens: number;
  };

  export type ContextBreakdownDetail = 'summary' | 'full';

  export type ContextCategory = {
      name: string;
      tokens: number;
      color: string;
      isDeferred: boolean;
      kind: ContextCategoryKind;
  };

  export type ContextCategoryKind = 'used' | 'free' | 'buffer' | 'deferred';

  export type ContextGridSquare = {
      color: string;
      isFilled: boolean;
      categoryName: string;
      tokens: number;
      percentage: number;
      squareFullness: number;
  };

  export type ContextMcpTool = {
      name: string;
      serverName: string;
      tokens: number;
      isLoaded: boolean;
  };

  export type ContextMemoryFile = {
      path: string;
      type: string;
      tokens: number;
  };

  export type ContextSkill = {
      name: string;
      source: string;
      pluginName?: string;
      tokens: number;
  };

  export type ContextSkills = {
      totalSkills: number;
      includedSkills: number;
      tokens: number;
      skillFrontmatter: ContextSkill[];
  };

  export type ContextSlashCommands = {
      totalCommands: number;
      includedCommands: number;
      tokens: number;
  };

  export type ContextWindowSource = 'env' | 'settings' | 'clientdata' | 'experiment' | 'model-default' | 'unknown-model' | 'auto';

  export interface CoreEngineInterface {
      plugin: {
          name: string;
          root: string;
      };
      ui: {
          notice: (tool_use_id: string, text: string | undefined) => void;
          invalidate: (event: InvalidatableEventName) => void;
          blit: (args: UiBlitArgs) => Promise<UiBlitResult>;
          resolve: <E extends ResolveInput>(e: E) => Elements[E['surface']];
          log: (text: string, options?: UiLogOptions) => void;
          ask: (question: string, options?: readonly string[] | AskOptions) => Promise<string>;
          toast: (text: string, options?: ToastOptions) => void;
          status: (text: string | undefined) => void;
          open: (pane: PaneOpenArgs) => Promise<UiOpenResult>;
          close: (pane: PaneCloseArgs) => Promise<void>;
          panes: () => Promise<readonly UiPane[]>;
          scroll: (args: UiScrollArgs) => Promise<UiScrollResult>;
          focus: (args: UiFocusArgs) => Promise<UiFocusResult>;
          copy: (args: UiCopyArgs) => Promise<UiCopyResult>;
          selection: () => Promise<UiSelection | undefined>;
      };
      model: {
          complete: (request: ModelCompleteRequest, options?: ModelCompleteOptions) => Promise<ModelCompleteResult>;
          fork: (request: ModelForkRequest) => Promise<ModelForkResult>;
          classify: (text: string, labels: readonly string[], options?: ClassifyOptions) => Promise<string | undefined>;
      };
      audio: {
          play: (clip: AudioClip, options?: PlayOptions) => Promise<void>;
          speak: (text: string, options?: SpeakOptions) => Promise<SpeakResult>;
      };
      mcp: {
          call: (server: string, tool: string, args?: Record<string, unknown>) => Promise<McpToolResult>;
          connect: (server: string) => Promise<McpConnectResult>;
      };
      session: {
          messages: SessionMessagesCall;
          cwd: () => Promise<string>;
          root: () => Promise<string>;
          model: () => Promise<string>;
          turns: () => Promise<number>;
          id: () => Promise<string>;
          repo: () => Promise<SessionRepo | null>;
          surfaces: () => Promise<readonly RenderSurface[]>;
          surface: () => Promise<RenderSurface | null>;
          usage: (args?: SessionUsageArgs) => Promise<SessionUsage>;
          version: () => Promise<SessionVersion>;
          compact: EventCalls['session']['compact'];
          send: EventCalls['session']['send'];
          append: (args: SessionAppendArgs) => Promise<SessionAppendResult>;
          authorize: () => Promise<SessionAuthorization>;
      };
      turn: {
          abort: (input: OpEventOf['turn.abort']) => Promise<void>;
      };
      prompt: {
          submit: EventCalls['prompt']['submit'];
          read: () => Promise<PromptBox>;
          fill: (input: PromptFillArgs) => Promise<PromptFilled>;
          suggest: EventCalls['prompt']['suggest'];
          compose: EventCalls['prompt']['compose'];
      };
      tool: {
          list: () => Promise<ToolInfo[]>;
          call: EventCalls['tool']['call'];
          check: EventCalls['tool']['check'];
          register: (tool: ToolSpec) => Promise<OpValueOf['tool.register']>;
      };
      command: {
          list: () => Promise<CommandInfo[]>;
          run: EventCalls['command']['run'];
          register: (command: CommandSpec) => Promise<OpValueOf['command.register']>;
      };
      config: {
          list: () => Promise<ConfigRow[]>;
          set: EventCalls['config']['set'];
      };
      telemetry: {
          log: (entry: TelemetryLogArgs) => Promise<void>;
          mark: (entry: TelemetryMarkInput) => Promise<void>;
      };
      agent: {
          spawn: EventCalls['agent']['spawn'];
          list: () => Promise<AgentInfo[]>;
          register: (spec: AgentSpec) => Promise<OpValueOf['agent.register']>;
      };
      fs: {
          read: FsReadCall;
          write: (path: string, text: string) => Promise<void>;
          list: (path?: string) => Promise<FsEntry[]>;
          exists: (path: string) => Promise<boolean>;
          stat: (path: string, options?: FsStatOptions) => Promise<FsStat>;
          ancestors: (request: FsAncestorsRequest) => Promise<readonly FsAncestor[]>;
      };
      store: {
          get: (key: string) => Promise<unknown>;
          set: (key: string, value: unknown) => Promise<void>;
          delete: (key: string) => Promise<void>;
          keys: () => Promise<string[]>;
      };
      state: {
          get: <P extends keyof PluginState & string, K extends keyof PluginState[P] & string>(ref: StateRef<P, K>) => Promise<StateRead<StateValue<P, K>>>;
          set: <P extends keyof PluginState & string, K extends keyof PluginState[P] & string>(ref: StateRef<P, K>, value: StateValue<P, K>, options?: StateSetOptions) => Promise<StateSetResult>;
      };
      clock: {
          now: () => Promise<number>;
          sleep: (ms: number, options?: SleepOptions) => Promise<void>;
          after: TimerCall;
          every: TimerCall;
      };
      http: {
          fetch: (url: string, init?: HttpInit) => Promise<HttpResponse>;
      };
      process: {
          run: (argv: readonly string[], init?: ProcessRunInit) => Promise<ProcessRunResult>;
          spawn: (request: ProcessSpawnRequest) => HookStream<ProcessSpawnChunk, ProcessSpawnResult>;
      };
      settings: {
          read: (args?: SettingsReadArgs) => Promise<Settings>;
      };
      env: {
          get: (name: string) => Promise<string | undefined>;
          set: (name: string, value: string | undefined) => Promise<void>;
      };
  }

  type CoreEventName = keyof CoreEventOf;

  type CoreEventOf = EngineEventOf & ClassicEventOf & OpEventOf;

  type CwdChangedHookInput = BaseHookInput & {
      hook_event_name: 'CwdChanged';
      old_cwd: string;
      new_cwd: string;
  };

  type DeclaredAttachmentInput<K extends keyof PromptAttachmentDetailOf> = {
      type: K;
      text: string;
      origin: PromptAttachmentOrigin;
      agentId?: string;
      detail?: PromptAttachmentDetailOf[K];
  };

  type DeclaredEvents<Pair> = Pair extends readonly [
  infer P extends keyof PluginState & string,
  infer K
  ] ? K extends keyof PluginState[P] & string ? DeclaredEventsOf<P, K> : never : never;

  type DeclaredEventsOf<P extends keyof PluginState & string, K extends keyof PluginState[P] & string> = {
      get: StateRef<P, K>;
      set: StateRef<P, K> & DeclaredStateChange<P, K>;
  };

  type DeclaredPair = {
      [P in keyof PluginState & string]: {
          [K in keyof PluginState[P] & string]: readonly [plugin: P, key: K];
      }[keyof PluginState[P] & string];
  }[keyof PluginState & string];

  type DeclaredStateChange<P extends keyof PluginState & string, K extends keyof PluginState[P] & string> = {
      value: StateValue<P, K>;
      previous: StateValue<P, K> | undefined;
      ifVersion?: number;
  };

  export type Derived<T> = {
      readonly sources: readonly (Atom<unknown> | StateAddress)[];
      readonly compute: (...values: never[]) => T;
  };

  export type DeriveFunction = <const S extends readonly unknown[], T>(sources: S, compute: (...values: SourceValues<S>) => T) => Derived<T>;

  type DirectoryAddedHookInput = BaseHookInput & {
      hook_event_name: 'DirectoryAdded';
      directory: string;
      source: 'slash_command' | 'register_repo_root';
  };

  export type ElementChildren = {
      children?: RenderChildren;
  };

  export type ElementConstructor<P> = (props: P & ElementChildren) => RenderElement;

  export type ElementName = {
      [P in RenderSurface]: keyof Elements[P];
  }[RenderSurface];

  export type Elements = {
      terminal: {
          Box: ElementConstructor<BoxProps>;
          Text: ElementConstructor<TextProps>;
          Button: ElementConstructor<ButtonProps>;
          Input: ElementConstructor<InputProps>;
          Select: ElementConstructor<SelectProps>;
          Link: ElementConstructor<LinkProps>;
          Code: ElementConstructor<CodeProps>;
          Markdown: ElementConstructor<MarkdownProps>;
          Client: ElementConstructor<ClientProps>;
          Raster: ElementConstructor<RasterProps>;
          Image: ElementConstructor<ImageProps>;
      };
      desktop: {
          Box: ElementConstructor<BoxProps>;
          Text: ElementConstructor<TextProps>;
          Button: ElementConstructor<ButtonProps>;
          Input: ElementConstructor<InputProps>;
          Select: ElementConstructor<SelectProps>;
          Svg: ElementConstructor<SvgProps>;
          Link: ElementConstructor<LinkProps>;
          Code: ElementConstructor<CodeProps>;
          Markdown: ElementConstructor<MarkdownProps>;
          Client: ElementConstructor<ClientProps>;
      };
      mobile: {
          Box: ElementConstructor<BoxProps>;
          Text: ElementConstructor<TextProps>;
          Button: ElementConstructor<ButtonProps>;
          Svg: ElementConstructor<SvgProps>;
          Link: ElementConstructor<LinkProps>;
          Code: ElementConstructor<CodeProps>;
          Markdown: ElementConstructor<MarkdownProps>;
      };
      vscode: {
          Box: ElementConstructor<BoxProps>;
          Text: ElementConstructor<TextProps>;
          Button: ElementConstructor<ButtonProps>;
          Input: ElementConstructor<InputProps>;
          Select: ElementConstructor<SelectProps>;
          Svg: ElementConstructor<SvgProps>;
          Link: ElementConstructor<LinkProps>;
          Code: ElementConstructor<CodeProps>;
          Markdown: ElementConstructor<MarkdownProps>;
      };
  };

  export type ElementTable<P extends RenderSurface = RenderSurface> = Elements[P];

  type ElicitationHookInput = BaseHookInput & {
      hook_event_name: 'Elicitation';
      mcp_server_name: string;
      message: string;
      mode?: 'form' | 'url';
      url?: string;
      elicitation_id?: string;
      requested_schema?: Record<string, unknown>;
  };

  type ElicitationResultHookInput = BaseHookInput & {
      hook_event_name: 'ElicitationResult';
      mcp_server_name: string;
      elicitation_id?: string;
      mode?: 'form' | 'url';
      action: 'accept' | 'decline' | 'cancel';
      content?: Record<string, unknown>;
  };

  export type EngineCreateInput = {
      plugins: readonly string[];
  };

  export type EngineCreateResult = Partial<EngineInterface> & {
      readonly [noun: string]: unknown;
  };

  export type EngineEventOf = {
      'tool.call': ToolCallInput;
      'tool.check': ToolCheckInput;
      'ui.render': RenderInput;
      'ui.resolve': ResolveInput;
      'ui.press': UiPressArgument;
      'ui.input': UiInputArgument;
      'ui.select': UiSelectArgument;
      'ui.message': UiMessageArgument;
      'ui.fault': UiFaultInput;
      'ui.scroll': UiScrollInput;
      'ui.focus': UiFocusInput;
      'agent.offer': AgentOfferInput;
      'agent.spawn': AgentSpawnInput;
      'prompt.submit': PromptSubmitInput;
      'prompt.fill': PromptFillInput;
      'prompt.suggest': PromptSuggestInput;
      'prompt.edit': PromptEditInput;
      'prompt.autocomplete': PromptAutocompleteInput;
      'prompt.section': PromptSectionInput;
      'prompt.context': PromptContextInput;
      'prompt.compose': PromptComposeInput;
      'prompt.attachment': PromptAttachmentInput;
      'prompt.mention': PromptMentionInput;
      'tool.describe': ToolDescribeInput;
      'command.run': CommandRunInput;
      'command.describe': CommandDescribeInput;
      'config.set': ConfigSetInput;
      'config.describe': ConfigDescribeInput;
      'telemetry.log': TelemetryLogInput;
      'telemetry.mark': TelemetryMarkInput;
      'skill.prompt': SkillPromptInput;
      'attribution.text': AttributionTextInput;
      'session.start': SessionStartInput;
      'session.receive': SessionReceiveInput;
      'session.append': SessionAppendInput;
      'session.send': SessionSendInput;
      'session.compact': SessionCompactInput;
      'session.attach': SessionAttachInput;
      'session.detach': SessionDetachInput;
      'session.measure': SessionMeasureInput;
      'session.end': SessionEndInput;
      'plugin.register': PluginRegisterInput;
      'turn.start': TurnStartInput;
      'turn.step': TurnStepInput;
      'turn.complete': TurnCompleteInput;
      'engine.create': EngineCreateInput;
  };

  export interface EngineInterface extends CoreEngineInterface {
  }

  export type EngineInterfaceBuilt = EngineInterface & {
      readonly [noun: string]: unknown;
  };

  export type EngineResultOf = {
      'tool.call': ToolCallResult;
      'tool.check': ToolCheckResult;
      'ui.render': RenderElement;
      'ui.resolve': ElementTable;
      'ui.press': UiPressResult;
      'ui.input': UiInputResult;
      'ui.select': UiSelectResult;
      'ui.message': UiMessageResult;
      'ui.fault': UiFaultResult;
      'ui.scroll': UiScrollResult;
      'ui.focus': UiFocusResult;
      'agent.offer': AgentOfferResult;
      'agent.spawn': AgentSpawnResult;
      'prompt.submit': PromptSubmitResult;
      'prompt.fill': PromptFillResult;
      'prompt.suggest': PromptSuggestResult;
      'prompt.edit': PromptEditResult;
      'prompt.autocomplete': PromptAutocompleteResult;
      'prompt.section': PromptSectionResult;
      'prompt.context': PromptContextResult;
      'prompt.compose': PromptComposeResult;
      'prompt.attachment': PromptAttachmentResult;
      'prompt.mention': PromptMentionResult;
      'tool.describe': ToolDescribeResult;
      'command.run': CommandRunResult;
      'command.describe': CommandDescribeResult;
      'config.set': ConfigSetResult;
      'config.describe': ConfigDescribeResult;
      'telemetry.log': TelemetryLogResult;
      'telemetry.mark': TelemetryMarkResult;
      'skill.prompt': SkillPromptResult;
      'attribution.text': AttributionTextResult;
      'session.start': SessionStartResult;
      'session.receive': SessionReceiveResult;
      'session.append': SessionAppendResult;
      'session.send': SessionSendResult;
      'session.compact': SessionCompactResult;
      'session.attach': SessionAttachResult;
      'session.detach': SessionDetachResult;
      'session.measure': SessionMeasureResult;
      'session.end': SessionEndResult;
      'plugin.register': PluginRegisterResult;
      'turn.start': TurnStartResult;
      'turn.step': TurnStepResult;
      'turn.complete': TurnCompleteResult;
      'engine.create': EngineCreateResult;
  };

  export type EventCalls = {
      tool: {
          call: ToolCallOverloads;
          check: (input: ToolCheckArgs) => Promise<ToolCheckResult>;
          describe: (input: ToolDescribeInput) => Promise<ToolDescribeResult>;
      };
      command: {
          run: (input: CommandRunArgs) => Promise<CommandRunResult>;
          describe: (input: CommandDescribeInput) => Promise<CommandDescribeResult>;
      };
      config: {
          set: (input: ConfigSetArgs) => Promise<ConfigSetResult>;
          describe: (input: ConfigDescribeInput) => Promise<ConfigDescribeResult>;
      };
      prompt: {
          submit: (input: PromptSubmitArgs) => Promise<PromptSubmitResult>;
          fill: (input: PromptFillArgs) => Promise<PromptFillResult>;
          suggest: (input: PromptSuggestArgs) => Promise<PromptSuggestResult>;
          section: (input: PromptSectionInput) => Promise<PromptSectionResult>;
          context: (input: PromptContextInput) => Promise<PromptContextResult>;
          attachment: (input: PromptAttachmentInput) => Promise<PromptAttachmentResult>;
          mention: (input: PromptMentionInput) => Promise<PromptMentionResult>;
          compose: (input?: PromptComposeArgs) => Promise<PromptComposeResult>;
      };
      skill: {
          prompt: (input: SkillPromptInput) => Promise<SkillPromptResult>;
      };
      attribution: {
          text: (input: AttributionTextInput) => Promise<AttributionTextResult>;
      };
      agent: {
          offer: (input: AgentOfferInput) => Promise<AgentOfferResult>;
          spawn: (input: AgentSpawnArgs) => Promise<AgentSpawnResult>;
      };
      session: {
          start: (input: SessionStartInput) => Promise<SessionStartResult>;
          receive: (input: SessionReceiveInput) => Promise<SessionReceiveResult>;
          append: (input: SessionAppendInput) => Promise<SessionAppendResult>;
          send: (input: SessionSendArgs) => Promise<SessionSendResult>;
          compact: (input?: SessionCompactArgs) => Promise<SessionCompactResult>;
          attach: (input: SessionAttachInput) => Promise<SessionAttachResult>;
          detach: (input: SessionDetachInput) => Promise<SessionDetachResult>;
          measure: (input: SessionMeasureInput) => Promise<SessionMeasureResult>;
          end: (input: SessionEndInput) => Promise<SessionEndResult>;
      };
      telemetry: {
          log: (input: TelemetryLogArgs) => Promise<TelemetryLogResult>;
          mark: (input: TelemetryMarkInput) => Promise<TelemetryMarkResult>;
      };
      turn: {
          start: (input: TurnStartInput) => Promise<TurnStartResult>;
          step: (input: TurnStepInput) => HookStream<TurnStepChunk, TurnStepResult>;
          complete: (input: TurnCompleteInput) => Promise<TurnCompleteResult>;
      };
      ui: {
          render: <C extends RenderComponent>(input: RenderInput<C>) => Promise<RenderElement>;
          resolve: <E extends ResolveInput>(e: E) => Elements[E['surface']];
          scroll: (input: UiScrollArgs) => Promise<UiScrollResult>;
          focus: (input: UiFocusArgs) => Promise<UiFocusResult>;
      };
  };

  export type EventName = keyof EventOf;

  export type EventOf = CoreEventOf & NounEventOf;

  export type EventResult<N extends EventName = EventName> = ResultOf[N];

  export type Events = {
      [E in keyof EventOf]: E extends StreamingEventName ? StreamHook<E> : ($: E extends 'engine.create' ? NoEngineInterface : EngineInterface, e: Frozen<Args<E>>, next: Next<E>) => EventResult<E> | Promise<EventResult<E>>;
  };

  type ExitReason = 'clear' | 'resume' | 'logout' | 'prompt_input_exit' | 'other';

  type FileChangedHookInput = BaseHookInput & {
      hook_event_name: 'FileChanged';
      file_path: string;
      event: 'change' | 'add' | 'unlink';
  };

  export type Frozen<T> = T extends string | ((...args: never[]) => unknown) ? T : T extends readonly unknown[] ? {
      [K in keyof T]: Frozen<T[K]>;
  } : T extends object ? {
      readonly [K in keyof T]: Frozen<T[K]>;
  } : T;

  export type FsAncestor = {
      dir: string;
      name: string;
      content: string;
      parts: readonly FsAncestorPart[];
  };

  export type FsAncestorPart = {
      path: string;
      content: string;
  };

  export type FsAncestorsRequest = {
      names: readonly string[];
      of?: string;
      below?: string;
  };

  export type FsBytes = {
      base64: string;
  };

  export type FsEntry = {
      name: string;
      kind: 'file' | 'dir' | 'other';
      size: number;
      mtimeMs: number;
      isLink: boolean;
  };

  export type FsReadAs = 'text' | 'bytes';

  export type FsReadBytesOptions = {
      as: 'bytes';
  };

  export type FsReadCall = {
      (path: string): Promise<string>;
      (path: string, options: FsReadBytesOptions): Promise<FsBytes>;
      (path: string, options: FsReadOptions): Promise<string | FsBytes>;
  };

  export type FsReadOptions = {
      as: FsReadAs;
  };

  export type FsStat = {
      kind: 'file' | 'dir' | 'other';
      size: number;
      mtimeMs: number;
      isLink: boolean;
      realPath?: string;
  };

  export type FsStatOptions = {
      resolve: boolean;
  };

  export type Glob = '*' | `${Namespace}.*`;

  export type GlobHook<P extends Pattern, N extends EventName = Selected<P>> = ($: EngineInterface, e: Frozen<Args<N>>, next: GlobNext<P>) => EventResult<N> | Promise<EventResult<N>>;

  export type GlobNext<P extends Pattern, N extends EventName = Selected<P>> = OrderedOverloads<N> & {
      (e: Args<N>): Promise<GlobNextResult<N>>;
      readonly to: (e: Args<N>, tier: TargetTier) => Promise<GlobNextResult<N>>;
      readonly signal: AbortSignal;
      readonly is: <M extends PatternOver<N>>(pattern: M, e: unknown) => e is Frozen<Args<Extract<N, Selected<M>>>>;
      readonly event: N;
      readonly origin: Origin;
      readonly trace: readonly TraceEntry<N, Args<N>, GlobNextResult<N>>[];
      readonly budget: NextBudget;
  };

  type GlobNextResult<N extends EventName> = {
      [K in N]: NextResult<K>;
  }[N];

  export type Hook<E extends EventName = EventName> = Events[E];

  export type HookBudget = {
      readonly ms: 10_000;
      readonly catchMs: 1_000;
      readonly lingerMs: 5_000;
  };

  export type HookFailure = {
      readonly kind: 'throw' | 'timeout' | 're-entry';
      readonly cause?: 'lent';
      readonly message?: string;
      readonly budget: number;
  };

  export type HookFor<P extends Pattern> = P extends '*' ? AnyEventHook : P extends EventName ? Events[P] : GlobHook<P>;

  type HookInput = PreToolUseHookInput | PostToolUseHookInput | PostToolUseFailureHookInput | PostToolBatchHookInput | PermissionDeniedHookInput | NotificationHookInput | UserPromptSubmitHookInput | UserPromptExpansionHookInput | SessionStartHookInput | SessionEndHookInput | StopHookInput | StopFailureHookInput | SubagentStartHookInput | SubagentStopHookInput | PreCompactHookInput | PostCompactHookInput | PreModelSwitchHookInput | PostModelSwitchHookInput | PermissionRequestHookInput | SetupHookInput | TeammateIdleHookInput | TaskCreatedHookInput | TaskCompletedHookInput | ElicitationHookInput | ElicitationResultHookInput | ConfigChangeHookInput | InstructionsLoadedHookInput | WorktreeCreateHookInput | WorktreeRemoveHookInput | CwdChangedHookInput | FileChangedHookInput | DirectoryAddedHookInput | MessageDisplayHookInput;

  export type HookOf<E extends EventName> = Events[E];

  export type HooksModule = {
      register: Register;
  };

  export type HookStream<C, R> = AsyncGenerator<C, R> & {
      readonly result: Promise<R>;
  };

  export type HttpInit = {
      method?: string;
      headers?: Record<string, string>;
      body?: string;
      auth?: string;
      socketPath?: string;
  };

  export type HttpResponse = {
      status: number;
      ok: boolean;
      headers: Record<string, string>;
      text: string;
  };

  export type ImageBlitArgs = {
      requestId: string;
      key: string;
      source: ImageSource;
      columns?: number;
      rows?: number;
  };

  export type ImageProps = {
      key?: string;
      source: ImageSource;
      columns: number;
      rows: number;
      alt: string;
  };

  export type ImageSource = {
      png: string;
  } | {
      rgba: string;
      width: number;
      height: number;
  } | {
      file: string;
      format: 'png';
      generation?: number;
  } | {
      file: string;
      format: 'rgba' | 'rgb';
      width: number;
      height: number;
      generation?: number;
  } | {
      shm: string;
      format: 'rgba' | 'rgb';
      width: number;
      height: number;
      generation?: number;
  };

  type ImpossibleKeys<E, P, D extends readonly unknown[]> = {
      [K in keyof P]-?: K extends keyof E ? [NarrowedValue<Exclude<E[K], undefined>, P[K], D>] extends [never] ? K : never : K;
  }[keyof P];

  type IndexFree<T> = {
      [K in keyof T as string extends K ? never : number extends K ? never : K]: 0;
  };

  export type InputProps = {
      key: string;
      label?: string;
      placeholder?: string;
      value?: string;
      submitLabel?: string;
      autoFocus?: true;
      onInput?: (value: string, e: UiInputArgument) => void;
      onSubmit: (value: string, e: UiInputArgument) => void;
  };

  const INSTRUCTION_FILE_KINDS: readonly ["managed", "user", "project", "local", "memory"];

  export type InstructionFile = {
      path: string;
      kind: InstructionFileKind;
      content: string;
      parent?: string;
  };

  export type InstructionFileKind = (typeof INSTRUCTION_FILE_KINDS)[number];

  type InstructionsLoadedHookInput = BaseHookInput & {
      hook_event_name: 'InstructionsLoaded';
      file_path: string;
      memory_type: 'User' | 'Project' | 'Local' | 'Managed';
      load_reason: 'session_start' | 'nested_traversal' | 'path_glob_match' | 'include' | 'compact';
      globs?: string[];
      trigger_file_path?: string;
      parent_file_path?: string;
  };

  export type InvalidatableEventName = RenderEventName | 'prompt.section' | 'prompt.context' | 'prompt.attachment' | 'tool.describe' | 'command.describe' | 'config.describe';

  type IsDiscriminant<I, K> = I extends unknown ? K extends KnownKeys<I> ? IsSingleLiteral<I[K & keyof I]> : true : never;

  type IsLiteralValued<V> = string extends V ? false : number extends V ? false : boolean extends V ? false : [V] extends [string | number | boolean] ? true : false;

  type IsSingleLiteral<V> = [V] extends [string | number | boolean] ? IsUnion<V> extends true ? false : true : false;

  type IsUnion<T, U = T> = T extends unknown ? [U] extends [T] ? false : true : never;

  export type JsonValue = string | number | boolean | null | readonly JsonValue[] | {
      readonly [key: string]: JsonValue;
  };

  type KeptEvent<P extends Pattern, M> = MatchedNames<P, M> extends infer N extends EventName ? N extends unknown ? KeptMembers<Args<N>, M> : never : never;

  type KeptMembers<E, P> = E extends unknown ? [ImpossibleKeys<E, P, []>] extends [never] ? E : never : never;

  type KnownKeys<T> = keyof (string extends keyof T ? IndexFree<T> : number extends keyof T ? IndexFree<T> : T);

  type LateOverload = 'classic.PreToolUse' | 'turn.abort' | NoArgsEvent;

  export type LinkProps = {
      href: string;
      label?: string;
  };

  type Literal<X> = X extends RegExp ? unknown : X;

  export type MarkdownLeafProps = {
      key?: string;
      text: string;
      dimColor?: boolean;
      pressableLinks?: readonly string[];
  };

  export type MarkdownProps = {
      key?: string;
      text: string;
      dimColor?: boolean;
      onLinkPress?: (link: PressedLink, e: UiPressArgument) => void;
      pressableLinks?: readonly string[];
  };

  export type MatchedEvent<P extends Pattern, M> = MatchedNames<P, M> extends infer N extends EventName ? N extends unknown ? Narrowed<Args<N>, M> : never : never;

  export type MatchedHook<P extends Pattern, M> = P extends StreamingEventName ? MatchedStreamHook<P, M> : ($: EngineInterface, e: Frozen<MatchedEvent<P, M>>, next: Next<MatchedNames<P, M>, KeptEvent<P, M>, MatchedResult<P, M>, {
      [K in MatchedNames<P, M>]: Narrowed<Args<K>, M>;
  }>) => MatchedResult<P, M> | Promise<MatchedResult<P, M>>;

  type MatchedNames<P, M = never> = (P extends EventName ? P : {
      [N in Selected<P & string>]: [M] extends [never] ? N : keyof M extends AnyKeyOf<Args<N>> ? N : never;
  }[Selected<P & string>]) extends infer Names extends EventName ? Names : never;

  export type MatchedResult<P extends Pattern, M> = MatchedNames<P, M> extends infer N extends EventName ? N extends unknown ? Select<EventResult<N>, Selection<Args<N>, M>> : never : never;

  export type MatchedStreamHook<P extends StreamingEventName, M> = ($: EngineInterface, e: Frozen<MatchedEvent<P, M>>, next: MatchedStreamNext<P, M>) => StreamHookBody<Chunk<P>, MatchedResult<P, M>>;

  type MatchedStreamNarrowings<P extends StreamingEventName, M> = {
      [K in P]: Narrowed<Args<K>, M>;
  };

  type MatchedStreamNext<P extends StreamingEventName, M> = StreamNext<P, KeptEvent<P, M>, MatchedResult<P, M>, MatchedStreamNarrowings<P, M>>;

  export type Matcher<I, All = I> = I extends unknown ? {
      readonly [K in KnownKeys<I>]?: MatcherValue<I[K & keyof I], MatcherValueOf<All, K>>;
  } & (string extends keyof I ? OpenMatcher<I, All> : unknown) : never;

  type MatcherData = string | number | boolean | null | RegExp | readonly MatcherData[] | {
      readonly [key: string]: MatcherData;
  };

  type MatcherFor<P extends Pattern> = Matcher<Args<MatchedNames<P>>> extends infer Settled ? Settled : never;

  type MatcherKeys<I> = I extends unknown ? KnownKeys<I> : never;

  type MatcherOne<V> = unknown extends V ? MatcherData : V extends readonly (infer Item)[] ? MatcherOne<Item> : V extends string | number | boolean | null ? V | RegExp : V extends object ? Matcher<V> : V extends undefined ? never : unknown;

  type MatcherValue<V, Across = V> = MatcherOne<V> | readonly MatcherOne<Across>[];

  type MatcherValueAcross<I, K> = I extends unknown ? K extends KnownKeys<I> ? I[K & keyof I] : never : never;

  type MatcherValueOf<I, K> = [I] extends [unknown] ? symbol extends K ? MatcherValueAcross<I, K> : MatcherValues<I>[K & PropertyKey] : never;

  type MatcherValues<I> = {
      [Entry in I extends unknown ? {
          [K in KnownKeys<I>]-?: [key: K, value: I[K & keyof I]];
      }[KnownKeys<I>] : never as Entry[0]]: Entry[1];
  } & Record<PropertyKey, never>;

  type McpConnectRefusal = 'unlisted' | 'unapproved' | 'disabled' | 'policy' | 'auth' | 'failed';

  type McpConnectResult = {
      isConnected: true;
      server: string;
  } | {
      isConnected: false;
      reason: McpConnectRefusal;
      message: string;
  };

  export type McpContentBlock = {
      type: string;
      text?: string;
      uri?: string;
      mimeType?: string;
      [field: string]: unknown;
  };

  type McpServerProvenance = {
      name: string;
      source: string;
  };

  export type McpToolCallInput = [keyof McpToolInputs] extends [never] ? McpToolCallInputFallback : {
      [N in keyof McpToolInputs & string]: ToolInputOf<N, McpToolInputs[N] & Record<string, unknown>>;
  }[keyof McpToolInputs & string];

  type McpToolCallInputFallback = {
      tool: McpToolName;
      tool_use_id: string;
      [argument: string]: unknown;
  };

  export interface McpToolInputs {
  }

  export type McpToolName = `mcp__${string}__${string}`;

  export type McpToolResult = {
      content: McpContentBlock[];
      isError: boolean;
      structuredContent?: unknown;
  };

  export type MemberOfFunction = {
      <T>(family: Atom<T>, e: Pick<RenderInput, 'requestId'>): Atom<T>;
      <P extends string, K extends string>(family: StateName<P, K>, e: Pick<RenderInput, 'requestId'>): StateName<P, K> & Readonly<Required<Pick<StateAddress, 'id'>>>;
  };

  type MessageDisplayHookInput = BaseHookInput & {
      hook_event_name: 'MessageDisplay';
      turn_id: string;
      message_id: string;
      index: number;
      final: boolean;
      delta: string;
  };

  export type ModelApiError = ClassicHookInputs['StopFailure']['error'];

  export type ModelCompleteInput = {
      model: string;
      prompt: string;
      system?: string;
      promptBlocks?: readonly ModelTextBlock[];
      systemBlocks?: readonly ModelTextBlock[];
      maxTokens?: number;
      effort?: ModelEffort;
      timeoutMs?: number;
  };

  export type ModelCompleteOptions = {
      signal?: AbortSignal;
  };

  export type ModelCompleteRequest = {
      model: string;
      prompt: string | readonly ModelTextBlock[];
      system?: string | readonly ModelTextBlock[];
      maxTokens?: number;
      effort?: ModelEffort;
      timeoutMs?: number;
  };

  export type ModelCompleteResult = {
      isAnswered: true;
      text: string;
      usage: ModelUsage;
  } | {
      isAnswered: false;
      reason: 'api-error';
      status: number | null;
      error: ModelApiError;
      usage: ModelUsage;
  } | {
      isAnswered: false;
      reason: 'empty-reply';
      usage: ModelUsage;
  } | {
      isAnswered: false;
      reason: 'aborted';
      usage: ModelUsage;
  };

  export type ModelEffort = 'low' | 'medium' | 'high' | 'xhigh' | 'max';

  export type ModelForkRequest = {
      prompt: string;
  };

  export type ModelForkResult = ModelCompleteResult | {
      isAnswered: false;
      reason: 'nothing-to-fork';
  };

  export type ModelTextBlock = {
      text: string;
      cache?: true;
  };

  export type ModelUsage = {
      input_tokens: number;
      output_tokens: number;
      cache_read_input_tokens: number;
      cache_creation_input_tokens: number;
  };

  export type Namespace<N extends string = EventName> = N extends `${infer Head}.${infer Rest}` ? Head | `${Head}.${Namespace<Rest>}` : never;

  type NarrowDepth = 8;

  export type Narrowed<E, P> = E extends unknown ? NarrowedMember<E, P, []> : never;

  type NarrowedByAny<V, Alternatives extends readonly unknown[], D extends readonly unknown[], Found = never> = Alternatives extends readonly [infer First, ...infer Rest] ? NarrowedByAny<V, Rest, D, Found | NarrowedByOne<V, First, D>> : Alternatives extends readonly [] ? Found : Found | NarrowedByOne<V, Alternatives[number], D>;

  type NarrowedByOne<V, Q, D extends readonly unknown[]> = V extends readonly (infer Item)[] ? [NarrowedValue<Item, Q, [...D, unknown]>] extends [never] ? never : NonEmpty<V, Item> : Q extends RegExp ? V : Q extends object ? V extends object ? NarrowedMember<V, Q, [...D, unknown]> : never : V extends Q ? V : Q extends V ? Q : never;

  type NarrowedMember<E, P, D extends readonly unknown[]> = [
  ImpossibleKeys<E, P, D>
  ] extends [never] ? {
      [K in keyof E]: K extends keyof P ? NarrowedValue<E[K], P[K], D> : E[K];
  } : never;

  type NarrowedValue<V, Q, D extends readonly unknown[]> = D['length'] extends NarrowDepth ? V : unknown extends V ? V : Q extends readonly unknown[] ? NarrowedByAny<V, Q, D> : NarrowedByOne<V, Q, D>;

  type Negation = `!${Exclude<EventName | Glob, '*'>}`;

  export type Next<N extends EventName = EventName, E = Args<N>, O = NextResult<N>, S extends {
      [K in N]?: unknown;
  } = {
      [K in N]: Args<K>;
  }> = {
      <T extends string>(e: E & ToolNamed<T>): Promise<NextResultFor<N, O, T>>;
      (e: E): Promise<O>;
      readonly to: {
          <T extends string>(e: E & ToolNamed<T>, tier: TargetTier): Promise<NextResultFor<N, O, T>>;
          (e: E, tier: TargetTier): Promise<O>;
      };
      readonly signal: AbortSignal;
      readonly is: <M extends PatternOver<N>>(pattern: M, e: unknown) => e is Frozen<S[Extract<N, Selected<M>>]>;
      readonly event: N;
      readonly origin: Origin;
      readonly trace: readonly TraceEntry<N, E, O>[];
      readonly budget: NextBudget;
  };

  export type NextBudget = {
      readonly ms: number;
      readonly remainingMs: number;
  };

  export type NextResult<N extends EventName> = N extends 'engine.create' ? EngineInterfaceBuilt : EventResult<N>;

  export type NextResultFor<N extends EventName, O, T extends string> = [
  N
  ] extends ['tool.call'] ? ToolCallResult<T> : O;

  type NoArgs = Record<never, never>;

  type NoArgsEvent = {
      [N in EventName]: Args<N> extends NoArgs ? NoArgs extends Args<N> ? N : never : never;
  }[EventName];

  export type NoEngineInterface = {
      readonly [noun: string]: never;
  };

  type NonEmpty<V, Item> = V extends readonly [unknown, ...unknown[]] ? V : V extends Item[] ? [Item, ...Item[]] : readonly [Item, ...Item[]];

  type NotificationHookInput = BaseHookInput & {
      hook_event_name: 'Notification';
      message: string;
      title?: string;
      notification_type: string;
  };

  type NounEvent = {
      [K in PluginNoun]: {
          [M in keyof EngineInterface[K] & string]: EngineInterface[K][M] extends (...args: infer Parameters) => infer Result ? NounEventRow<`${K}.${M}`, Parameters extends readonly [] ? NoArgs : Parameters[0], Awaited<Result>> : never;
      }[keyof EngineInterface[K] & string];
  }[PluginNoun];

  type NounEventName = keyof NounEventOf & string;

  export type NounEventOf = {
      [E in NounEvent as E['name']]: E['args'];
  };

  type NounEventResult<N extends NounEventName> = ValueOrDeny<NounValueOf[N]>;

  type NounEventRow<Name extends string, Args, Value> = {
      name: Name;
      args: Args;
      value: Value;
  };

  type NounValueOf = {
      [E in NounEvent as E['name']]: E['value'];
  };

  export type On = {
      <P extends Pattern>(pattern: P, hook: NoInfer<HookFor<P>>): Registration<HookFor<P>>;
      <P extends Pattern, const M extends MatcherFor<P>>(pattern: P, matcher: M, hook: NoInfer<MatchedHook<P, M>>): Registration<MatchedHook<P, M>>;
  };

  type OnScreen = {
      first: number;
      last: number;
      of: number;
  };

  type OpenMatcher<I, All> = {
      readonly [K in Exclude<MatcherKeys<All>, keyof IndexFree<I>>]?: MatcherValue<MatcherValueOf<All, K>>;
  } & Readonly<Record<string, unknown>>;

  export type OpEventName = keyof OpEventOf;

  export type OpEventOf = {
      'model.complete': ModelCompleteInput;
      'model.classify': {
          text: string;
          labels: readonly string[];
          options?: ClassifyOptions;
      };
      'model.fork': ModelForkRequest;
      'audio.play': {
          clip: AudioClip;
          shouldLoop: boolean;
          gain?: number;
      };
      'audio.speak': SpeakRequest;
      'mcp.call': {
          server: string;
          tool: string;
          args: Record<string, unknown>;
      };
      'mcp.connect': {
          server: string;
      };
      'session.cwd': NoArgs;
      'session.root': NoArgs;
      'session.model': NoArgs;
      'session.turns': NoArgs;
      'session.id': NoArgs;
      'session.messages': SessionMessagesArgs;
      'session.repo': NoArgs;
      'session.surface': NoArgs;
      'session.surfaces': NoArgs;
      'session.authorize': NoArgs;
      'session.usage': SessionUsageArgs;
      'session.version': NoArgs;
      'turn.abort': {
          turnId: string;
      };
      'prompt.read': NoArgs;
      'tool.list': NoArgs;
      'tool.register': RegisteredToolSpec;
      'command.list': NoArgs;
      'command.register': CommandSpec;
      'config.list': NoArgs;
      'agent.list': NoArgs;
      'agent.register': AgentSpec;
      'ui.toast': {
          text: string;
          timeoutMs?: number;
      };
      'ui.status': {
          text: string | undefined;
      };
      'ui.log': {
          text: string;
          to: UiLogSink;
      };
      'ui.notice': {
          tool_use_id: string;
          text: string | undefined;
      };
      'ui.invalidate': {
          event: InvalidatableEventName;
      };
      'ui.open': PaneOpenArgs;
      'ui.close': PaneCloseInput;
      'ui.panes': NoArgs;
      'ui.selection': NoArgs;
      'ui.copy': UiCopyArgs;
      'ui.blit': UiBlitArgs;
      'fs.read': {
          path: string;
          as: FsReadAs;
      };
      'fs.write': {
          path: string;
          text: string;
      };
      'fs.list': {
          path: string;
      };
      'fs.exists': {
          path: string;
      };
      'fs.stat': {
          path: string;
          resolve: boolean;
      };
      'fs.ancestors': FsAncestorsRequest;
      'store.get': {
          key: string;
      };
      'store.set': {
          key: string;
          value: unknown;
      };
      'store.delete': {
          key: string;
      };
      'store.keys': NoArgs;
      'state.get': StateGetEvent;
      'state.set': StateSetEvent;
      'clock.now': NoArgs;
      'clock.sleep': ClockWait;
      'clock.after': ClockWait;
      'clock.every': ClockWait;
      'http.fetch': {
          url: string;
          init?: HttpInit;
      };
      'process.run': {
          argv: readonly string[];
          init?: ProcessRunInit;
      };
      'process.spawn': ProcessSpawnRequest;
      'settings.read': SettingsReadArgs;
      'env.get': {
          name: string;
      };
      'env.set': {
          name: string;
          value?: string;
      };
  };

  export type OpEventResult<N extends OpEventName = OpEventName> = ValueOrDeny<OpValueOf[N]>;

  export type OpValueOf = {
      'model.complete': ModelCompleteResult;
      'model.classify': string | undefined;
      'model.fork': ModelForkResult;
      'audio.play': void;
      'audio.speak': SpeakResult;
      'mcp.call': McpToolResult;
      'mcp.connect': McpConnectResult;
      'session.cwd': string;
      'session.root': string;
      'session.model': string;
      'session.turns': number;
      'session.id': string;
      'session.messages': SessionMessagesValue;
      'session.repo': SessionRepo | null;
      'session.surface': RenderSurface | null;
      'session.surfaces': readonly RenderSurface[];
      'session.authorize': SessionAuthorization;
      'session.usage': SessionUsage;
      'session.version': SessionVersion;
      'turn.abort': void;
      'prompt.read': PromptBox;
      'tool.list': ToolInfo[];
      'tool.register': {
          tool: string;
      };
      'command.list': CommandInfo[];
      'command.register': {
          command: string;
      };
      'config.list': ConfigRow[];
      'agent.list': AgentInfo[];
      'agent.register': {
          agent: string;
      };
      'ui.toast': void;
      'ui.status': void;
      'ui.log': void;
      'ui.notice': void;
      'ui.invalidate': void;
      'ui.open': UiOpenResult;
      'ui.close': void;
      'ui.panes': readonly UiPane[];
      'ui.selection': UiSelection | undefined;
      'ui.copy': UiCopyResult;
      'ui.blit': UiBlitResult;
      'fs.read': string | FsBytes;
      'fs.write': void;
      'fs.list': FsEntry[];
      'fs.exists': boolean;
      'fs.stat': FsStat;
      'fs.ancestors': readonly FsAncestor[];
      'store.get': unknown;
      'store.set': void;
      'store.delete': void;
      'store.keys': string[];
      'state.get': StateRead;
      'state.set': StateSetResult;
      'clock.now': number;
      'clock.sleep': void;
      'clock.after': void;
      'clock.every': void;
      'http.fetch': HttpResponse;
      'process.run': ProcessRunResult;
      'process.spawn': ProcessSpawnResult;
      'settings.read': Settings;
      'env.get': string | undefined;
      'env.set': void;
  };

  type OrderedOverloads<Names extends EventName> = Overloads<Exclude<Names, LateOverload>> & Overloads<Extract<Names, 'classic.PreToolUse'>> & Overloads<Extract<Names, 'turn.abort'>> & Overloads<Extract<Names, NoArgsEvent>>;

  export type Origin = {
      readonly plugin: string;
      readonly tier: Tier;
  };

  type Overloads<Names extends EventName> = UnionToIntersection<{
      [N in Names]: (e: Args<N>) => Promise<NextResult<N>>;
  }[Names]>;

  export type PaneCloseArgs = Omit<PaneCloseInput, 'origin'>;

  export type PaneCloseInput = {
      id: string;
      origin: PaneCloseOrigin;
  };

  export type PaneCloseOrigin = {
      kind: 'plugin' | 'person' | 'unload';
  };

  export type PaneOpenArgs = {
      id: string;
      title?: string;
      focus?: true;
      closeOnEscape?: true;
      holdToasts?: true;
      rows?: number;
      columns?: number;
  };

  export type Pattern = EventName | Glob | Negation;

  type PatternOver<N extends EventName> = N | '*' | `${Namespace<N>}.*` | Negation;

  type PermissionBehavior = 'allow' | 'deny' | 'ask';

  type PermissionDeniedHookInput = BaseHookInput & {
      hook_event_name: 'PermissionDenied';
      tool_name: string;
      tool_input: unknown;
      tool_use_id: string;
      reason: string;
      mcp_server?: McpServerProvenance;
  };

  type PermissionMode = 'default' | 'acceptEdits' | 'bypassPermissions' | 'plan' | 'dontAsk' | 'auto';

  export type PermissionRequestDecision = {
      behavior: 'allow';
      updatedInput?: Record<string, unknown>;
      updatedPermissions?: PermissionUpdates;
  } | {
      behavior: 'deny';
      message?: string;
      interrupt?: true;
  };

  type PermissionRequestHookInput = BaseHookInput & {
      hook_event_name: 'PermissionRequest';
      tool_name: string;
      tool_input: unknown;
      permission_suggestions?: PermissionUpdate[];
      mcp_server?: McpServerProvenance;
  };

  type PermissionRuleValue = {
      toolName: string;
      ruleContent?: string;
  };

  type PermissionUpdate = {
      type: 'addRules';
      rules: PermissionRuleValue[];
      behavior: PermissionBehavior;
      destination: PermissionUpdateDestination;
  } | {
      type: 'replaceRules';
      rules: PermissionRuleValue[];
      behavior: PermissionBehavior;
      destination: PermissionUpdateDestination;
  } | {
      type: 'removeRules';
      rules: PermissionRuleValue[];
      behavior: PermissionBehavior;
      destination: PermissionUpdateDestination;
  } | {
      type: 'setMode';
      mode: PermissionMode;
      destination: PermissionUpdateDestination;
  } | {
      type: 'addDirectories';
      directories: string[];
      destination: PermissionUpdateDestination;
  } | {
      type: 'removeDirectories';
      directories: string[];
      destination: PermissionUpdateDestination;
  };

  type PermissionUpdateDestination = 'userSettings' | 'projectSettings' | 'localSettings' | 'session' | 'cliArg';

  type PermissionUpdates = NonNullable<ClassicHookInputs['PermissionRequest']['permission_suggestions']>;

  type PlanModeDetail = {
      reminder: 'full' | 'sparse';
      planFilePath: string;
      hasPlan: boolean;
  };

  type PlanModeExitDetail = {
      planFilePath: string;
      hasPlan: boolean;
  };

  type PlanModeReentryDetail = {
      planFilePath: string;
  };

  export type PlayOptions = {
      shouldLoop: true;
      gain?: number;
      signal: AbortSignal;
  } | {
      shouldLoop?: false;
      gain?: number;
      signal?: AbortSignal;
  };

  type PluginNoun = Exclude<keyof EngineInterface & string, keyof CoreEngineInterface | Namespace<CoreEventName>>;

  export type PluginOptions = Readonly<Record<string, string | number | boolean | readonly string[]>>;

  export type PluginRegisterInput = {
      name: string;
      tier: Exclude<Tier, 'core'>;
      root: string;
      version?: string;
      provenance: string;
      uses: PluginRegisterUses;
  };

  export type PluginRegisterResult = {
      allow: true;
      refuse?: undefined;
  } | {
      refuse: string;
      allow?: undefined;
  };

  export type PluginRegisterUses = {
      events: readonly string[];
      calls: readonly string[];
      env?: {
          reads: readonly string[];
          writes: readonly string[];
      };
      state?: {
          reads: readonly StateName[];
          writes: readonly StateName[];
      };
  };

  type PluginStamp = {
      plugin: string;
  };

  export interface PluginState {
  }

  type PostCompactHookInput = BaseHookInput & {
      hook_event_name: 'PostCompact';
      trigger: 'manual' | 'auto';
      compact_summary: string;
  };

  type PostModelSwitchHookInput = (BaseHookInput & {
      hook_event_name: 'PostModelSwitch';
  }) & {
      from_model: string;
      to_model: string;
      requested_model: string | null;
      source: 'command' | 'picker' | 'sdk' | 'auto' | 'resume';
      context_tokens: number;
      prompt_cache_warm: boolean;
      cache_ttl: '5m' | '1h';
      estimated_cache_write_usd: number;
      pricing: 'configured' | 'catalog' | 'default';
  };

  type PostToolBatchHookInput = BaseHookInput & {
      hook_event_name: 'PostToolBatch';
      tool_calls: PostToolBatchToolCall[];
  };

  type PostToolBatchToolCall = {
      tool_name: string;
      tool_input: unknown;
      tool_use_id: string;
      tool_response?: unknown;
  };

  type PostToolUseFailureHookInput = BaseHookInput & {
      hook_event_name: 'PostToolUseFailure';
      tool_name: string;
      tool_input: unknown;
      tool_use_id: string;
      error: string;
      is_interrupt?: boolean;
      duration_ms?: number;
      mcp_server?: McpServerProvenance;
  };

  type PostToolUseHookInput = BaseHookInput & {
      hook_event_name: 'PostToolUse';
      tool_name: string;
      tool_input: unknown;
      tool_response: unknown;
      tool_use_id: string;
      duration_ms?: number;
      mcp_server?: McpServerProvenance;
  };

  type PreCompactHookInput = BaseHookInput & {
      hook_event_name: 'PreCompact';
      trigger: 'manual' | 'auto';
      custom_instructions: string | null;
  };

  type PreModelSwitchHookInput = (BaseHookInput & {
      hook_event_name: 'PreModelSwitch';
  }) & {
      from_model: string;
      to_model: string;
      requested_model: string | null;
      source: 'command' | 'picker' | 'sdk';
      context_tokens: number;
      prompt_cache_warm: boolean;
      cache_ttl: '5m' | '1h';
      estimated_cache_write_usd: number;
      pricing: 'configured' | 'catalog' | 'default';
  };

  export type PressedLink = {
      href: string;
  };

  export type PreToolUseDecision = {
      allow: true;
      ask?: undefined;
      deny?: undefined;
  } | {
      ask: string;
      allow?: undefined;
      deny?: undefined;
  } | {
      deny: string;
      allow?: undefined;
      ask?: undefined;
  } | {
      allow?: undefined;
      ask?: undefined;
      deny?: undefined;
  };

  type PreToolUseHookInput = BaseHookInput & {
      hook_event_name: 'PreToolUse';
      tool_name: string;
      tool_input: unknown;
      tool_use_id: string;
      mcp_server?: McpServerProvenance;
  };

  export type PreToolUseResult = PreToolUseDecision & {
      updatedInput?: Record<string, unknown>;
      additionalContext?: string[];
  };

  export type ProcessRunInit = {
      cwd?: string;
      env?: Record<string, string>;
      stdin?: string;
      timeoutMs?: number;
  };

  export type ProcessRunResult = {
      exitCode: number;
      stdout: string;
      stderr: string;
      isStdoutTruncated: boolean;
      isStderrTruncated: boolean;
  };

  export type ProcessSpawnChunk = {
      stream: 'stdout' | 'stderr';
      text: string;
  };

  export type ProcessSpawnRequest = {
      argv: readonly string[];
      cwd?: string;
      env?: Record<string, string>;
      input?: string;
  };

  export type ProcessSpawnResult = {
      code: number | null;
      signal: string | null;
  };

  export type PromptAttachmentDetailOf = {
      plan_mode: PlanModeDetail;
      plan_mode_reentry: PlanModeReentryDetail;
      plan_mode_exit: PlanModeExitDetail;
  };

  export type PromptAttachmentInput = {
      [K in keyof PromptAttachmentDetailOf]: DeclaredAttachmentInput<K>;
  }[keyof PromptAttachmentDetailOf] | UndeclaredAttachmentInput;

  export type PromptAttachmentOrigin = {
      kind: 'engine';
  } | {
      kind: 'hook';
      event: string;
  } | {
      kind: 'plugin';
      event: string;
  };

  export type PromptAttachmentResult = {
      text: string | null;
  };

  export type PromptAutocompleteInput = {
      text: string;
      cursor: number;
      token: string;
      start: number;
  };

  export type PromptAutocompleteResult = {
      suggestions: readonly PromptAutocompleteSuggestion[];
  };

  export type PromptAutocompleteSuggestion = {
      text: string;
      label?: string;
      description?: string;
  };

  export type PromptBox = {
      text: string;
      cursor: number;
  };

  export type PromptComposeArgs = Partial<PromptComposeInput>;

  export type PromptComposeInput = {
      model: string;
      promptModel: string;
      surfaces: readonly RenderSurface[];
      tools: readonly string[];
      outputStyle: {
          name: string;
          isKeepingCodingInstructions: boolean;
      } | null;
      traits: readonly PromptComposeTrait[];
  };

  export type PromptComposeResult = {
      sections: readonly PromptComposeSection[];
  };

  export type PromptComposeScope = 'shared' | 'session';

  export type PromptComposeSection = {
      id: string;
      text: string;
      scope: PromptComposeScope;
  };

  export type PromptComposeTrait = 'bare' | 'lean' | 'sdk-preset' | 'teammate' | 'analysis' | 'print' | 'skills' | 'send-user-message';

  export type PromptContextBlock = {
      name: string;
      text: string;
  };

  export type PromptContextBlocks = {
      blocks: readonly PromptContextBlock[];
  };

  export type PromptContextInput = {
      blocks: readonly PromptContextBlock[];
      instructionFiles?: readonly InstructionFile[];
  };

  export type PromptContextResult = {
      blocks: readonly PromptContextBlock[];
      instructionFiles?: readonly InstructionFile[];
  };

  export type PromptDecoration = {
      start: number;
      end: number;
  } & Pick<TextProps, 'color' | 'backgroundColor' | 'dimColor' | 'bold' | 'italic' | 'underline' | 'strikethrough'>;

  export type PromptEditInput = {
      origin: PromptEditOrigin;
      key?: ClientKeyEvent;
      text: string;
      cursor: number;
      start: number;
      end: number;
      inputText: string;
  };

  export type PromptEditOrigin = {
      kind: 'composer';
  };

  export type PromptEditResult = PromptBox & {
      decorations?: PromptDecoration[];
  };

  export type PromptFillArgs = {
      text: string;
      mode?: PromptFillMode;
      decorations?: PromptDecoration[];
  };

  export type PromptFilled = {
      isFilled: boolean;
      refusal?: 'no_composer' | 'dialog';
      text: string;
      cursor: number;
  };

  export type PromptFillInput = {
      text: string;
      mode: PromptFillMode;
      origin: PromptFillOrigin;
      decorations?: PromptDecoration[];
  };

  export type PromptFillMode = 'replace' | 'append' | 'insert';

  export type PromptFillOrigin = {
      kind: 'engine';
  } | {
      kind: 'plugin';
      name: string;
  };

  export type PromptFillResult = {
      isFilled: boolean;
      refusal?: 'no_composer' | 'dialog';
  };

  export type PromptMentionAttached = 'file' | 'already_read_file' | 'pdf_reference';

  export type PromptMentionInput = {
      mention: string;
      path: string;
      offset?: number;
      limit?: number;
      agentId?: string;
  };

  export type PromptMentionResult = {
      type: PromptMentionAttached | null;
      context?: readonly string[];
      deny?: undefined;
  } | {
      deny: string;
      type?: undefined;
      context?: undefined;
  };

  export type PromptOrigin = {
      kind: 'composer';
  } | {
      kind: 'bridge';
  } | {
      kind: 'sdk';
  } | {
      kind: 'task-notification';
  } | {
      kind: 'scheduled-trigger';
  } | {
      kind: 'peer';
  } | {
      kind: 'peer-send-message';
  } | {
      kind: 'projects-relay';
  } | {
      kind: 'channel';
      server: string;
  } | {
      kind: 'coordinator';
  } | {
      kind: 'observer';
  } | {
      kind: 'observer-activity';
  } | {
      kind: 'auto-continuation';
  } | {
      kind: 'unclassified';
  } | {
      kind: 'slack-ping';
  } | {
      kind: 'plugin';
      name: string;
      asUser?: true;
  };

  export type PromptSectionInput = {
      name: string;
      text: string | null;
  };

  export type PromptSectionResult = {
      text: string | null;
  };

  export type PromptSubmitArgs = Omit<PromptSubmitInput, 'origin' | 'turnId' | 'wait' | 'context'> & {
      asUser?: true;
  };

  export type PromptSubmitAttachment = {
      type: 'image' | 'audio' | 'document';
      mediaType?: string;
      filename?: string;
  };

  export type PromptSubmitInput = {
      text: string;
      attachments?: readonly PromptSubmitAttachment[];
      context?: readonly string[];
      turnId?: string;
      wait: boolean;
      origin: PromptOrigin;
  };

  export type PromptSubmitResult = {
      text: string;
      context?: readonly string[];
      origin?: PromptOrigin;
      drop?: undefined;
  } | {
      drop: string;
      text?: undefined;
      context?: undefined;
      origin?: undefined;
  };

  export type PromptSuggestArgs = Omit<PromptSuggestInput, 'origin'>;

  export type PromptSuggestInput = {
      text: string;
      origin: PromptSuggestOrigin;
  };

  export type PromptSuggestOrigin = {
      kind: 'suggestion';
  } | {
      kind: 'plugin';
      name: string;
  };

  export type PromptSuggestResult = {
      isShown: boolean;
  };

  export type RasterBlitArgs = {
      requestId: string;
      key: string;
      cells: string;
      columns?: number;
      rows?: number;
  };

  export type RasterProps = {
      key: string;
      columns: number;
      rows: number;
      cells: string;
  };

  export type ReadFunction = {
      <T>($: StateDollar, source: Atom<T>): Promise<T>;
      <T>($: StateDollar, source: Derived<T>): Promise<T>;
      <P extends keyof PluginState & string, K extends keyof PluginState[P] & string>($: StateDollar, source: StateRef<P, K>): Promise<StateValue<P, K> | undefined>;
  };

  export type Register = (on: On, options: PluginOptions) => unknown;

  export type RegisteredToolSpec = {
      name: string;
      description: string;
      inputSchema: Record<string, unknown>;
      isDeferred?: ToolDeferral;
  };

  export type Registration<F> = {
      readonly catch: (handler: CatchHandler<F>) => void;
  };

  export type RenderChildren = RenderNode | number | boolean | null | undefined | readonly RenderChildren[];

  export type RenderComponent = 'AskUserQuestion' | 'UserMessage' | 'AssistantMessage' | 'ToolUse' | 'ToolResult' | 'ToolGroup' | 'ToolProgress' | 'CommandOutput' | 'Spinner' | 'TurnDuration' | 'InfoNotice' | 'SessionMode' | 'PromptHint' | 'AbovePrompt' | 'Pane';

  export type RenderElement = StyledElement<'Box', BoxHoverProps> | StyledElement<'Text', TextHoverProps> | {
      type: 'Button';
      props: {
          key: string;
          label: string;
          hotkey?: string;
          action?: string;
          plain?: true;
          dimColor?: TextProps['dimColor'];
          variant?: ButtonProps['variant'];
          role?: ButtonProps['role'];
          autoFocus?: true;
      };
      press: {
          plugin: string;
          handle: number;
      };
      hover?: TextHoverProps;
  } | {
      type: 'Input';
      props: {
          key: string;
          label?: string;
          placeholder?: string;
          value?: string;
          submitLabel?: string;
          autoFocus?: true;
      };
      press: {
          plugin: string;
          handle: number;
      };
      children?: undefined;
  } | {
      type: 'Select';
      props: {
          key: string;
          label?: string;
          options: readonly SelectOption[];
          value?: string;
          autoFocus?: true;
      };
      press: {
          plugin: string;
          handle: number;
      };
      children?: undefined;
  } | {
      type: 'Link';
      props: LinkProps;
      children?: RenderNode[];
  } | {
      type: 'Code';
      props: CodeProps;
      children?: undefined;
  } | {
      type: 'Markdown';
      props: MarkdownLeafProps;
      children?: undefined;
  } | {
      type: 'Markdown';
      props: MarkdownLeafProps;
      press: {
          plugin: string;
          handle: number;
      };
      children?: undefined;
  } | {
      type: 'Client';
      props: ClientProps;
      client: {
          plugin: string;
      };
      children?: undefined;
  } | {
      type: 'Svg';
      props: SvgProps;
      children?: undefined;
  } | {
      type: 'Raster';
      props: RasterProps;
      raster: {
          plugin: string;
      };
      children?: undefined;
  } | {
      type: 'Image';
      props: ImageProps;
      image: {
          plugin: string;
      };
      children?: undefined;
  } | {
      type: 'engine';
      ref: number;
  };

  export type RenderEventName = 'ui.render';

  export type RenderInput<C extends RenderComponent = RenderComponent, P extends RenderSurface = RenderSurface> = C extends RenderComponent ? P extends RenderSurface ? RenderInputOf<C, P> : never : never;

  export type RenderInputOf<C extends RenderComponent, P extends RenderSurface> = {
      surface: P;
      component: C;
      requestId: string;
      viewport?: RenderViewport;
      props: RenderPropsOf[C];
  };

  export type RenderNode = RenderElement | string;

  export type RenderPropsOf = {
      AskUserQuestion: {
          tool: string;
          questions: unknown[];
          metadataSource?: string;
      };
      UserMessage: {
          text: string;
          origin: PromptOrigin;
          isExpanded: boolean;
          task?: UserMessageTask;
          from?: UserMessageFrom;
          onScreen?: OnScreen | null;
      };
      AssistantMessage: {
          text: string;
          isFirstOfReply: boolean;
          isSummary?: true;
          onScreen?: OnScreen | null;
      };
      ToolUse: {
          tool_use_id: string;
          tool: string;
          input: unknown;
          isRunning: boolean;
          isErrored: boolean;
          isInterrupted: boolean;
          output?: unknown;
          onScreen?: OnScreen | null;
      };
      ToolResult: {
          tool_use_id: string;
          tool: string;
          output: unknown;
          isErrored: boolean;
          onScreen?: OnScreen | null;
      };
      ToolGroup: {
          calls: ReadonlyArray<ToolGroupCall>;
          isActive: boolean;
          isExpanded: boolean;
          onScreen?: OnScreen | null;
      };
      CommandOutput: {
          command: string;
          args: string;
          text: string;
          isErrored: boolean;
          onScreen?: OnScreen | null;
      };
      ToolProgress: {
          tool_use_id: string;
          kind: 'background_hint';
          hint: string;
      };
      Spinner: {
          word: string;
          message: string | null;
          suffix: string;
          mode: 'requesting' | 'responding' | 'thinking' | 'tool-input' | 'tool-use';
      };
      TurnDuration: {
          word: string;
          durationMs: number;
          onScreen?: OnScreen | null;
      };
      InfoNotice: {
          text: string;
          command: string | null;
          onScreen?: OnScreen | null;
      };
      SessionMode: {
          modes: readonly string[];
      };
      PromptHint: {
          isDraft: boolean;
          isWorking: boolean;
          hint: string;
          tail?: string;
      };
      AbovePrompt: {
          hasSurvey: boolean;
          isWorking: boolean;
          maxRows: number;
          bodyColumns: number;
          scroll: SiteScroll;
          view: SiteView;
      };
      Pane: {
          title: string;
          isFocused: boolean;
          bodyColumns: number;
          placement: 'dock' | 'inline';
          scroll: SiteScroll;
          view: SiteView;
      };
  };

  export type RenderResultOf = {
      [C in RenderComponent]: RenderElement;
  };

  export type RenderSurface = 'terminal' | 'desktop' | 'mobile' | 'vscode';

  export type RenderViewport = {
      columns: number;
      rows: number;
      isFullscreen?: boolean;
  };

  export type ResolveInput<C extends RenderComponent = RenderComponent, P extends RenderSurface = RenderSurface> = P extends RenderSurface ? ResolveInputOf<C, P> : never;

  export type ResolveInputOf<C extends RenderComponent, P extends RenderSurface> = {
      surface: P;
      component: C;
  };

  export type ResultOf = EngineResultOf & ClassicResultOf & {
      [N in OpEventName]: OpEventResult<N>;
  } & {
      [N in NounEventName]: NounEventResult<N>;
  };

  type SDKAssistantMessageError = 'authentication_failed' | 'oauth_org_not_allowed' | 'account_on_hold' | 'verification_required' | 'billing_error' | 'rate_limit' | 'overloaded' | 'invalid_request' | 'model_not_found' | 'server_error' | 'unknown' | 'max_output_tokens' | 'cloud_credential_error';

  type Select<T, S> = [Extract<T, S>] extends [never] ? T : Extract<T, S>;

  export type Selected<P extends string> = P extends '*' ? EventName : P extends `!${infer Negated}` ? Exclude<EventName, Selected<Negated>> : P extends `${infer Prefix}.*` ? Extract<EventName, `${Prefix}.${string}`> : Extract<EventName, P>;

  type Selection<I, M> = {
      [K in keyof M & TagKeys<I, keyof M>]: Literal<M[K] extends readonly (infer One)[] ? One : M[K]>;
  };

  export type SelectOption = {
      value: string;
      label?: string;
  };

  export type SelectProps = {
      key: string;
      label?: string;
      options: readonly SelectOption[];
      value?: string;
      autoFocus?: true;
      onSelect: (value: string, e: UiSelectArgument) => void;
  };

  type SessionAppendArgs = {
      message: {
          type: 'user' | 'system';
          content: ApiContentBlock[];
      };
      agentId?: string;
  };

  type SessionAppendDoor = 'prompt' | 'command' | 'response' | 'tool-result' | 'tool-message' | 'delivery' | 'attachment' | 'hook-context' | 'note' | 'compaction' | 'notice';

  type SessionAppendInput = {
      message: SessionAppendMessage;
      door: SessionAppendDoor;
      origin: SessionAppendOrigin;
      uuid: string;
      agentId?: string;
  };

  type SessionAppendMessage = {
      type: 'user' | 'assistant' | 'attachment' | 'system';
      name?: string;
      role?: 'user' | 'assistant';
      isMeta?: true;
      content: ApiContentBlock[];
  };

  type SessionAppendOrigin = PromptOrigin | PromptAttachmentOrigin | {
      kind: 'model';
      model: string;
  } | {
      kind: 'tool';
      tool: string;
  };

  type SessionAppendResult = {
      message: SessionAppendMessage;
      uuid: string;
      deny?: undefined;
  } | {
      deny: string;
      message?: undefined;
      uuid?: undefined;
  };

  export type SessionAttachInput = {
      surface: RenderSurface;
      clientId: string;
      viewport?: RenderViewport;
  };

  export type SessionAttachResult = {
      clientId: string;
  };

  export type SessionAuthorization = {
      handle: string;
      kind: 'bearer' | 'api-key';
  } | null;

  export type SessionCompactArgs = {
      instructions?: string;
  };

  export type SessionCompacted = {
      messages: readonly SessionMessage[];
      tokensBefore?: number;
      tokensAfter?: number;
      usage?: ModelUsage;
      skip?: undefined;
  };

  export type SessionCompactInput = {
      trigger: SessionCompactTrigger;
      agentId?: string;
      instructions?: string;
      messages: readonly SessionMessage[];
  };

  export type SessionCompactResult = SessionCompacted | SessionCompactSkipped;

  export type SessionCompactSkipped = {
      skip: string;
      messages?: undefined;
  };

  export type SessionCompactTrigger = 'manual' | 'auto' | 'plugin' | 'precompute';

  export type SessionContextBreakdown = {
      categories: ContextCategory[];
      totalTokens: number;
      maxTokens: number;
      rawMaxTokens: number;
      autocompactSource: ContextWindowSource;
      percentage: number;
      gridRows: ContextGridSquare[][];
      model: string;
      memoryFiles: ContextMemoryFile[];
      mcpTools: ContextMcpTool[];
      agents: ContextAgent[];
      slashCommands?: ContextSlashCommands;
      skills?: ContextSkills;
      autoCompactThreshold?: number;
      isAutoCompactEnabled: boolean;
      apiUsage: ModelUsage | null;
  };

  export type SessionContextUsage = {
      tokens?: number;
      window: number;
      percent?: number;
      breakdown?: SessionContextBreakdown;
  };

  export type SessionCost = {
      usd: number;
  };

  type SessionCronSummary = {
      id: string;
      schedule: string;
      recurring: boolean;
      prompt: string;
  };

  export type SessionDetachInput = {
      surface: RenderSurface;
      clientId: string;
      reason: SessionDetachReason;
  };

  export type SessionDetachReason = 'detach' | 'end';

  export type SessionDetachResult = {
      clientId: string;
  };

  type SessionEndHookInput = BaseHookInput & {
      hook_event_name: 'SessionEnd';
      reason: ExitReason;
  };

  export type SessionEndInput = {
      reason: SessionEndReason;
      sessionId: string;
      resume: SessionResume;
  };

  export type SessionEndReason = ClassicHookInputs['SessionEnd']['reason'];

  export type SessionEndResult = {
      sessionId: string;
  };

  export type SessionMeasureInput = {
      context: SessionContextUsage;
      rateLimits: SessionRateLimit[];
      cost?: SessionCost;
      changed: UsageUnit[];
  };

  export type SessionMeasureResult = {
      changed: UsageUnit[];
  };

  export type SessionMessage = {
      role: 'user' | 'assistant';
      text: string;
      toolUses: ToolUseSummary[];
      toolResults?: ToolResultSummary[];
      handle?: string;
  };

  type SessionMessagesAgentArgs = {
      agentId?: string;
      as?: undefined;
  };

  type SessionMessagesApiArgs = {
      as: 'api';
      agentId?: string;
  };

  type SessionMessagesApiResult = ApiMessage[] | SessionMessagesDeny;

  type SessionMessagesArgs = {
      agentId?: string;
      as?: 'api';
  };

  type SessionMessagesCall = {
      (): Promise<SessionMessage[]>;
      (args: SessionMessagesMainApiArgs): Promise<ApiMessage[]>;
      (args: SessionMessagesApiArgs): Promise<SessionMessagesApiResult>;
      (args: SessionMessagesAgentArgs): Promise<SessionMessagesResult>;
      (args: SessionMessagesArgs): Promise<SessionMessagesValue>;
  };

  type SessionMessagesDeny = {
      deny: string;
  };

  type SessionMessagesMainApiArgs = {
      as: 'api';
      agentId?: undefined;
  };

  type SessionMessagesResult = SessionMessage[] | SessionMessagesDeny;

  type SessionMessagesValue = SessionMessagesResult | SessionMessagesApiResult;

  export type SessionRateLimit = {
      kind: string;
      percentUsed: number;
      resetsAt?: string;
  };

  export type SessionReceiveEvent = {
      source: string;
      kind: string;
      from?: string;
      data: Record<string, unknown>;
      untrustedKeys: readonly string[];
  };

  export type SessionReceiveInput = {
      origin: SessionReceiveOrigin;
      text: string;
      event?: SessionReceiveEvent;
      agentId?: string;
  };

  export type SessionReceiveOrigin = {
      kind: 'bridge' | 'task-notification' | 'scheduled-trigger' | 'peer-send-message' | 'projects-relay' | 'slack-ping' | 'unclassified';
  } | {
      kind: 'peer' | 'coordinator';
      plugin?: string;
  } | {
      kind: 'peer' | 'coordinator';
      plugin?: string;
      teammate: string;
      isVerified: boolean;
  };

  export type SessionReceiveResult = {
      text: string;
      consumed?: undefined;
  } | {
      consumed: string;
      text?: undefined;
  };

  export type SessionRepo = {
      root: string;
      remote: string | null;
      internal: boolean;
      name: string | null;
  };

  export type SessionResume = {
      id: string;
  };

  export type SessionSendAddress = string | {
      sessionId: string;
  } | {
      agentId: string;
  };

  export type SessionSendArgs = {
      to: SessionSendAddress;
      text: string;
  };

  export type SessionSendInput = {
      to: string;
      text: string;
      origin: SessionSendOrigin;
      agentId?: string;
  };

  export type SessionSendOrigin = {
      kind: 'model';
  } | {
      kind: 'plugin';
      name: string;
  };

  export type SessionSendResult = {
      isDelivered: true;
      reason?: undefined;
  } | {
      isDelivered: false;
      reason: string;
  };

  type SessionStartHookInput = BaseHookInput & {
      hook_event_name: 'SessionStart';
      source: 'startup' | 'resume' | 'clear' | 'compact' | 'fork';
      agent_type?: string;
      model?: string;
      session_title?: string;
      seconds_since_last_response?: number;
      context_tokens?: number;
      prompt_cache_likely_expired?: boolean;
      estimated_cache_write_usd?: number;
  };

  export type SessionStartInput = {
      cwd: string;
      surface: RenderSurface | null;
      isInteractive: boolean;
  };

  export type SessionStartResult = {
      cwd: string;
  };

  export type SessionUsage = {
      startedAt: number;
      context: SessionContextUsage;
      rateLimits: SessionRateLimit[];
      cost?: SessionCost;
  };

  export type SessionUsageArgs = {
      breakdown?: ContextBreakdownDetail;
      columns?: number;
  };

  export type SessionVersion = {
      version: string;
      base?: string;
      builtAt?: string;
  };

  export type Settings = Readonly<Record<string, unknown>>;

  export type SettingsReadArgs = {
      source?: SettingsSource;
  };

  export type SettingsSource = 'user' | 'project' | 'local' | 'flag' | 'policy';

  type SetupHookInput = BaseHookInput & {
      hook_event_name: 'Setup';
      trigger: 'init' | 'maintenance';
  };

  export type Shaped<T> = {
      shape: string;
      value: T;
  };

  export type ShapedValue<V> = V extends Shaped<infer T> ? T : never;

  export type SiteScroll = {
      offset: number;
      bodyRows: number;
  };

  export type SiteView = {
      agentId?: string;
  };

  export type SkillPromptInput = {
      skill: string;
      text: string;
  };

  export type SkillPromptResult = {
      text: string;
  };

  export type SleepOptions = {
      signal?: AbortSignal;
  };

  export type SourceValues<S extends readonly unknown[]> = {
      [I in keyof S]: S[I] extends Atom<infer V> ? V : S[I] extends Derived<infer V> ? V : S[I] extends StateName<infer P, infer K> ? P extends keyof PluginState & string ? K extends keyof PluginState[P] & string ? StateValue<P, K> | undefined : unknown : unknown : unknown;
  };

  export type SpeakOptions = {
      voice?: string;
  };

  type SpeakRequest = SpeakOptions & {
      text: string;
  };

  export type SpeakResult = {
      via: 'system';
  };

  export type StarNext = OrderedOverloads<EventName> & {
      (e: unknown): Promise<unknown>;
      readonly to: (e: unknown, tier: TargetTier) => Promise<unknown>;
      readonly signal: AbortSignal;
      readonly is: <M extends Pattern>(pattern: M, e: unknown) => e is Frozen<Args<Selected<M>>>;
      readonly event: EventName;
      readonly origin: Origin;
      readonly trace: readonly TraceEntry<EventName, unknown, unknown>[];
      readonly budget: NextBudget;
  };

  export type StateAddress = {
      plugin: string;
      key: string;
      id?: string;
  };

  export type StateDollar = Pick<CoreEngineInterface, 'state'>;

  export type StateFamily<T> = {
      readonly byId: T;
  };

  export type StateGetEvent = [DeclaredPair] extends [never] ? StateAddress : DeclaredEvents<DeclaredPair>['get'];

  type StateName<P extends string = string, K extends string = string> = {
      readonly plugin: P;
      readonly key: K;
  };

  export type StateRead<T = unknown> = {
      value: T | undefined;
      version: number;
  };

  export type StateRef<P extends keyof PluginState & string, K extends keyof PluginState[P] & string> = StateName<P, K> & (PluginState[P][K] extends StateFamily<unknown> ? Readonly<Required<Pick<StateAddress, 'id'>>> : Readonly<Partial<Record<'id', undefined>>>);

  export type StateSetEvent = [DeclaredPair] extends [never] ? StateWrite : DeclaredEvents<DeclaredPair>['set'];

  export type StateSetOptions = {
      ifVersion?: number;
  };

  export type StateSetResult = {
      isSet: true;
      version: number;
  } | {
      isSet: false;
      version: number;
  };

  export type StateValue<P extends keyof PluginState & string, K extends keyof PluginState[P] & string> = PluginState[P][K] extends StateFamily<infer Member> ? Member : PluginState[P][K];

  export type StateWrite = StateAddress & {
      value: unknown;
      previous?: unknown;
      ifVersion?: number;
  };

  type StopFailureHookInput = BaseHookInput & {
      hook_event_name: 'StopFailure';
      error: SDKAssistantMessageError;
      error_details?: string;
      last_assistant_message?: string;
  };

  type StopHookInput = BaseHookInput & {
      hook_event_name: 'Stop';
      stop_hook_active: boolean;
      last_assistant_message?: string;
      background_tasks?: BackgroundTaskSummary[];
      session_crons?: SessionCronSummary[];
  };

  export type StreamHook<N extends StreamingEventName> = ($: EngineInterface, e: Frozen<Args<N>>, next: StreamNext<N>) => StreamHookBody<Chunk<N>, EventResult<N>>;

  export type StreamHookBody<C, R> = AsyncGenerator<C, R | void> & {
      readonly result?: never;
  };

  export type StreamingEventName = 'turn.step' | 'process.spawn';

  export type StreamNext<N extends StreamingEventName = StreamingEventName, E = Args<N>, O = EventResult<N>, S extends {
      [K in N]?: unknown;
  } = {
      [K in N]: Args<K>;
  }> = Pick<Next<N, E, O, S>, 'signal' | 'is' | 'event' | 'origin' | 'budget'> & {
      (e: E): HookStream<Chunk<N>, O>;
      readonly to: (e: E, tier: TargetTier) => HookStream<Chunk<N>, O>;
      readonly trace: readonly TraceEntry<N, E, O>[];
  };

  type StyledElement<Tag extends 'Box' | 'Text', Hover> = {
      type: Tag;
      props?: Record<string, string | number | boolean>;
      hover?: Hover;
      group?: PluginStamp;
      children?: RenderNode[];
  };

  type SubagentStartHookInput = BaseHookInput & {
      hook_event_name: 'SubagentStart';
      agent_id: string;
      agent_type: string;
  };

  type SubagentStopHookInput = BaseHookInput & {
      hook_event_name: 'SubagentStop';
      stop_hook_active: boolean;
      agent_id: string;
      agent_transcript_path: string;
      agent_type: string;
      last_assistant_message?: string;
      background_tasks?: BackgroundTaskSummary[];
      session_crons?: SessionCronSummary[];
  };

  export type SvgProps = {
      source: string;
      alt: string;
      width?: number;
      height?: number;
      isInteractive?: boolean;
  };

  type TagKeys<I, Among> = Among extends MatcherKeys<I> ? IsLiteralValued<MatcherValueOf<I, Among>> extends true ? IsDiscriminant<I, Among> extends true ? Among : never : never : never;

  export type TargetTier = Exclude<Tier, 'prepend' | 'user'>;

  type TaskCompletedHookInput = BaseHookInput & {
      hook_event_name: 'TaskCompleted';
      task_id: string;
      task_subject: string;
      task_description?: string;
      teammate_name?: string;
      team_name?: string;
  };

  type TaskCreatedHookInput = BaseHookInput & {
      hook_event_name: 'TaskCreated';
      task_id: string;
      task_subject: string;
      task_description?: string;
      teammate_name?: string;
      team_name?: string;
  };

  type TeammateIdleHookInput = BaseHookInput & {
      hook_event_name: 'TeammateIdle';
      teammate_name: string;
      team_name: string;
  };

  export type TelemetryAttribute = string | number | boolean | readonly string[];

  export type TelemetryChoice = {
      value: string;
      of: readonly string[];
  };

  export type TelemetryDestination = 'anthropic' | 'collector';

  export type TelemetryLogArgs = TelemetryRowArgs | TelemetryRecordEntry;

  export type TelemetryLogInput = TelemetryRowEntry | TelemetryRecordEntry;

  export type TelemetryLogResult = ValueOrDeny<undefined>;

  export type TelemetryMarkInput = {
      feature: string;
      kind: TelemetryMarkKind;
      reason?: string;
      props?: Readonly<Record<string, TelemetryProp>>;
  };

  export type TelemetryMarkKind = 'ok' | 'sad' | 'bad';

  export type TelemetryMarkResult = ValueOrDeny<undefined>;

  export type TelemetryProp = number | boolean | TelemetryChoice;

  export type TelemetryRecordEntry = {
      to: 'collector';
      event: string;
      attributes: Readonly<Record<string, TelemetryAttribute>>;
      loggedAt: string;
      span?: TelemetrySpan;
  };

  export type TelemetryRowArgs = {
      to?: 'anthropic';
      event: string;
      props?: Readonly<Record<string, TelemetryProp>>;
  };

  export type TelemetryRowEntry = {
      to: 'anthropic';
      event: string;
      props?: Readonly<Record<string, TelemetryProp>>;
  };

  export type TelemetrySpan = {
      traceId: string;
      spanId: string;
      traceFlags: number;
  };

  export type TextHoverProps = {
      scope?: string;
      color?: Color;
      backgroundColor?: Color;
      dimColor?: boolean;
      bold?: boolean;
      italic?: boolean;
      underline?: boolean;
      strikethrough?: boolean;
      inverse?: boolean;
  };

  export type TextProps = {
      hover?: TextHoverProps;
      color?: Color;
      backgroundColor?: Color;
      dimColor?: boolean;
      bold?: boolean;
      italic?: boolean;
      underline?: boolean;
      strikethrough?: boolean;
      inverse?: boolean;
      wrap?: 'wrap' | 'end' | 'middle' | 'truncate' | 'truncate-start' | 'truncate-middle' | 'truncate-end';
  };

  export type ThemeKey = 'text' | 'inverseText' | 'inactive' | 'subtle' | 'suggestion' | 'remember' | 'success' | 'error' | 'warning' | 'merged' | 'claude' | 'permission' | 'planMode' | 'autoAccept' | 'promptBorder' | 'bashBorder' | 'ide' | 'diffAdded' | 'diffRemoved' | 'diffAddedDimmed' | 'diffRemovedDimmed' | 'diffAddedWord' | 'diffRemovedWord';

  export type Tier = (typeof TIERS)[number];

  const TIERS: readonly ["prepend", "user", "append", "builtin", "core"];

  export type Timer = {
      cancel: () => void;
  };

  export type TimerCall = (ms: number, fn: () => void) => Timer;

  export type ToastOptions = {
      timeoutMs?: number;
  };

  export type ToolCallArgs = ToolCallEnvelope extends infer I ? I extends ToolCallEnvelope ? Omit<I, 'tool_use_id'> & ToolCallReserved<I['tool']> : never : never;

  export type ToolCallEnvelope = BuiltinToolCallInput | McpToolCallInput;

  export type ToolCallInput = ToolCallEnvelope & AgentLoop;

  type ToolCallOverloads = {
      <T extends string>(input: ToolCallArgs & ToolNamed<T>): Promise<ToolCallResult<T>>;
      (input: ToolCallArgs): Promise<ToolCallResult>;
  };

  export type ToolCallReserved<T> = {
      tool: T;
      tool_use_id?: string;
      consent?: string;
  };

  export type ToolCallResult<Name extends string = string> = {
      deny: string;
      result?: undefined;
      context?: undefined;
      ref?: undefined;
      text?: undefined;
      isError?: undefined;
      isReadOnly?: undefined;
  } | {
      result: ToolResultOf<Name>;
      context?: readonly string[];
      ref?: number;
      text?: string;
      isReadOnly?: true;
      isError?: undefined;
      deny?: undefined;
  } | {
      isError: true;
      result: unknown;
      text?: string;
      ref?: number;
      context?: readonly string[];
      isReadOnly?: true;
      deny?: undefined;
  };

  type ToolCheckArgs = Pick<ToolCheckInput, 'tool' | 'input'>;

  type ToolCheckDecision = 'allow' | 'ask' | 'deny';

  type ToolCheckInput = {
      tool: string;
      input: unknown;
      tool_use_id?: string;
      agentId?: string;
      ceiling?: ToolCheckDecision;
  };

  type ToolCheckResult = {
      decision: ToolCheckDecision;
      reason?: string;
      rule?: string;
      hook?: string;
      ceiling?: ToolCheckDecision;
  };

  export type ToolDeferral = boolean;

  export type ToolDescribeInput = {
      tool: string;
      description: string;
      isDeferred?: true;
      provider: Origin;
  };

  export type ToolDescribeResult = {
      description: string;
      isDeferred?: ToolDeferral;
  };

  type ToolEnvelope<Name, Arguments> = {
      tool: Name;
      tool_use_id: string;
  } & Arguments;

  export type ToolGroupCall = {
      tool_use_id?: string;
      tool: string;
      input: unknown;
      isRunning: boolean;
      isErrored: boolean;
      isInterrupted: boolean;
      output?: unknown;
  };

  export type ToolInfo = {
      name: string;
      description: string;
      mcp: boolean;
  };

  export type ToolInputOf<Name extends string, Arguments> = {
      [K in keyof ToolEnvelope<Name, Arguments>]: ToolEnvelope<Name, Arguments>[K];
  };

  type ToolNamed<T extends string> = {
      readonly tool: T;
  };

  export type ToolResultOf<Name extends string> = string extends Name ? unknown : Name extends keyof BuiltinToolResults & string ? BuiltinToolResults[Name] | (Name extends 'Agent' ? AgentCallRecord | AgentTeammateRecord : never) : unknown;

  export type ToolResultSummary = {
      tool_use_id: string;
      text: string;
      isError: boolean;
      result?: unknown;
  };

  export type ToolSpec = {
      name: string;
      description: string;
      inputSchema?: Record<string, unknown>;
      isDeferred?: ToolDeferral;
  };

  export type ToolUseSummary = {
      tool_use_id: string;
      tool: string;
      input: Record<string, unknown>;
      result?: unknown;
      text?: string;
      isError?: true;
      agentId?: string;
      durationMs?: number;
  };

  export type TraceEntry<N extends EventName = EventName, E = Args<N>, O = NextResult<N>> = {
      readonly index: number;
      readonly plugin: string;
      readonly tier: Tier;
      readonly event: N;
      readonly outcome: TraceOutcome;
      readonly reason?: string;
      readonly ms: number;
      readonly chunks?: number;
      readonly received: E;
      readonly returned: O | undefined;
  };

  export type TraceOutcome = 'caught' | 'expired' | 'kept' | 'passed' | 'rejected' | 'returned' | 'skipped';

  type TurnCompleteFields = {
      answer: string;
      durationMs: number;
      isAborted: boolean;
      turnId: string;
      agentId?: string;
      usage?: TurnUsage;
  };

  export type TurnCompleteInput = TurnCompleteFields & (TurnCompleteRefused | TurnCompleteUnrefused);

  export type TurnCompleteReason = 'answer' | 'aborted' | 'refusal' | 'error';

  type TurnCompleteRefused = {
      reason: 'refusal';
      refusal: TurnRefusal;
  };

  export type TurnCompleteResult = {
      text: string;
      usage?: TurnUsage;
  };

  type TurnCompleteUnrefused = {
      reason: Exclude<TurnCompleteReason, 'refusal'>;
  };

  export type TurnRefusal = {
      category: string | null;
      explanation: string | null;
  };

  export type TurnStartInput = {
      text: string;
      turnId: string;
  };

  export type TurnStartResult = {
      turnId: string;
  };

  export type TurnStepChunk = TurnStepTextChunk | TurnStepThinkingChunk | TurnStepToolChunk | TurnStepInputChunk | TurnStepStopChunk | TurnStepEngineChunk;

  export type TurnStepEngineChunk = {
      kind: 'engine';
      ref: number;
  };

  export type TurnStepInput = {
      turnId: string;
      index: number;
      model: string;
      effort?: 'low' | 'medium' | 'high' | 'xhigh' | 'max' | number;
      messageCount: number;
      agentId?: string;
  };

  export type TurnStepInputChunk = ChunkRef & {
      kind: 'input';
      index: number;
      json: string;
  };

  export type TurnStepResult = {
      turnId: string;
      index: number;
      answer: string;
      toolUses: readonly TurnStepToolUse[];
      serverToolUses?: readonly TurnStepServerToolUse[];
      stopReason: TurnStopReason;
      usage: TurnUsage | null;
  };

  export type TurnStepServerToolUse = {
      id: string;
      name: string;
      input: unknown;
      startedAt: number;
      endedAt?: number;
  };

  export type TurnStepStopChunk = ChunkRef & {
      kind: 'stop';
      stopReason: TurnStopReason;
      usage: TurnUsage | null;
  };

  export type TurnStepTextChunk = ChunkRef & {
      kind: 'text';
      index: number;
      text: string;
  };

  export type TurnStepThinkingChunk = ChunkRef & {
      kind: 'thinking';
      index: number;
      text: string;
  };

  export type TurnStepToolChunk = ChunkRef & {
      kind: 'tool';
      index: number;
      id: string;
      name: string;
  };

  export type TurnStepToolUse = {
      name: string;
      input: unknown;
  };

  type TurnStopReason = 'end_turn' | 'max_tokens' | 'stop_sequence' | 'tool_use' | 'pause_turn' | 'compaction' | 'refusal' | 'model_context_window_exceeded' | null;

  export type TurnUsage = ModelUsage & {
      model: string;
  };

  export type UiBlitArgs = RasterBlitArgs | ImageBlitArgs;

  export type UiBlitResult = {
      deny?: string;
  };

  export type UiCopyArgs = {
      text: string;
      surface?: RenderSurface;
  };

  export type UiCopyResult = {
      isCopied: true;
  } | {
      isCopied: false;
      reason: 'no-surface' | 'no-clipboard' | 'refused';
  };

  type UiFaultInput = {
      surface: RenderSurface;
      component: RenderComponent;
      requestId: string;
      element: string;
      module: string;
      phase: UiFaultPhase;
      reason: string;
  };

  type UiFaultPhase = 'load' | 'render' | 'run';

  type UiFaultResult = Record<string, never>;

  export type UiFocusArgs = {
      requestId: string;
      key: string;
  };

  export type UiFocusComponent = 'Pane' | 'AbovePrompt';

  export type UiFocusInput = {
      component: UiFocusComponent;
      requestId: string;
      plugin?: string;
      element?: string;
      origin: UiFocusOrigin;
  };

  export type UiFocusOrigin = {
      kind: 'person';
  } | {
      kind: 'plugin';
      name: string;
  };

  export type UiFocusResult = {
      deny?: string;
  };

  export type UiInputArgument = {
      plugin: string;
      element: string;
      component: RenderComponent;
      requestId: string;
      surface: RenderSurface;
      kind: 'change' | 'submit';
      value: string;
  };

  export type UiInputResult = {
      element: string;
      value: string;
  };

  export type UiLogOptions = {
      to?: UiLogSink;
  };

  export type UiLogSink = 'transcript' | 'debug';

  export type UiMessageArgument = {
      surface: RenderSurface;
      component: RenderComponent;
      requestId: string;
      element: string;
      module: string;
      data: unknown;
  };

  export type UiMessageResult = {
      props?: unknown;
  };

  export type UiOpenResult = {
      isPlaced: true;
  } | {
      isPlaced: false;
      reason: string;
  };

  export type UiPane = {
      id: string;
      title: string;
      isShown: boolean;
      isFocused: boolean;
      isPlaced: boolean;
  };

  export type UiPressArgument = {
      plugin: string;
      element: string;
      component: RenderComponent;
      requestId: string;
      surface: RenderSurface;
      link?: PressedLink;
  };

  export type UiPressResult = {
      element: string;
  };

  export type UiScrollArgs = {
      to: UiScrollTarget;
      in?: string;
      block?: UiScrollBlock;
  };

  export type UiScrollBlock = 'start' | 'center' | 'end' | 'nearest';

  export type UiScrollComponent = 'Pane' | 'AbovePrompt';

  export type UiScrollInput = {
      component: UiScrollComponent;
      requestId: string;
      offset: number;
      by: number;
      bodyRows: number;
      contentRows: number;
      origin: UiScrollOrigin;
      pointer?: UiScrollPointer;
  };

  export type UiScrollOrigin = {
      kind: 'person';
  } | {
      kind: 'plugin';
      name: string;
  };

  export type UiScrollPointer = {
      column: number;
      row: number;
  };

  export type UiScrollResult = {
      deny?: string;
  };

  export type UiScrollTarget = {
      requestId: string;
  } | {
      key: string;
  } | 'start' | 'end';

  export type UiSelectArgument = {
      plugin: string;
      element: string;
      component: RenderComponent;
      requestId: string;
      surface: RenderSurface;
      value: string;
  };

  type UiSelection = {
      text: string;
      requestId?: string;
  };

  export type UiSelectResult = {
      element: string;
      value: string;
  };

  type UndeclaredAttachmentInput = {
      type: string;
      text: string;
      origin: PromptAttachmentOrigin;
      agentId?: string;
      detail?: undefined;
  };

  type UnionToIntersection<U> = (U extends unknown ? (member: U) => void : never) extends (member: infer I) => void ? I : never;

  export type UpdateFunction = {
      <T>($: StateDollar, target: Atom<T>, change: (value: T) => T): Promise<T>;
      <P extends keyof PluginState & string, K extends keyof PluginState[P] & string>($: StateDollar, target: StateRef<P, K>, change: (value: StateValue<P, K> | undefined) => StateValue<P, K>): Promise<StateValue<P, K>>;
  };

  export type UsageUnit = 'context' | 'rateLimits' | 'cost';

  type UserMessageFrom = {
      name: string;
  };

  type UserMessageTask = {
      id?: string;
      status?: string;
      type?: string;
      toolUseId?: string;
      durationMs?: number;
  };

  type UserPromptExpansionHookInput = BaseHookInput & {
      hook_event_name: 'UserPromptExpansion';
      expansion_type: 'slash_command' | 'mcp_prompt';
      command_name: string;
      command_args: string;
      command_source?: string;
      prompt: string;
  };

  type UserPromptSubmitHookInput = BaseHookInput & {
      hook_event_name: 'UserPromptSubmit';
      prompt: string;
      source?: 'user' | 'sdk' | 'system' | 'loop_wakeup' | 'schedule_wakeup' | 'poll_event';
      session_title?: string;
  };

  type ValueOrDeny<Value> = {
      value: Value;
      deny?: undefined;
  } | {
      deny: string;
      value?: undefined;
  };

  type WorktreeCreateHookInput = BaseHookInput & {
      hook_event_name: 'WorktreeCreate';
      name: string;
  };

  type WorktreeRemoveHookInput = BaseHookInput & {
      hook_event_name: 'WorktreeRemove';
      worktree_path: string;
  };

  export const atom: AtomFunction

  export const derive: DeriveFunction

  export const memberOf: MemberOfFunction

  export const read: ReadFunction

  export const update: UpdateFunction

  global {
    const h: (
      tag: string | ((props: never) => RenderNode | null | undefined),
      props: Record<string, unknown> | null | undefined,
      ...children: unknown[]
    ) => RenderNode | null | undefined

    const Fragment: (props: { children?: RenderNode[] }) => RenderElement

    namespace JSX {
      type Element = RenderElement
      type Children = RenderChildren
      type ElementType = (props: never) => RenderNode | null | undefined
      interface IntrinsicElements {}
      interface ElementChildrenAttribute {
        children: unknown
      }
      interface IntrinsicAttributes {
        key?: string
      }
    }

    interface AbortSignal {
      readonly aborted: boolean
      readonly reason: unknown
      throwIfAborted(): void
      addEventListener(
        type: 'abort',
        listener: () => void,
        options?: { once?: boolean },
      ): void
      removeEventListener(type: 'abort', listener: () => void): void
    }
    var AbortSignal: {
      prototype: AbortSignal
      abort(reason?: unknown): AbortSignal
      timeout(milliseconds: number): AbortSignal
      any(signals: AbortSignal[]): AbortSignal
    }
    interface AbortController {
      readonly signal: AbortSignal
      abort(reason?: unknown): void
    }
    var AbortController: {
      prototype: AbortController
      new (): AbortController
    }
    interface TextEncoder {
      readonly encoding: string
      encode(input?: string): Uint8Array
    }
    var TextEncoder: { prototype: TextEncoder; new (): TextEncoder }
    interface TextDecoder {
      readonly encoding: string
      decode(input?: ArrayBufferView | ArrayBuffer): string
    }
    var TextDecoder: { prototype: TextDecoder; new (label?: string): TextDecoder }
    interface URLSearchParams {
      append(name: string, value: string): void
      delete(name: string): void
      get(name: string): string | null
      getAll(name: string): string[]
      has(name: string): boolean
      set(name: string, value: string): void
      toString(): string
      forEach(callback: (value: string, key: string) => void): void
    }
    var URLSearchParams: {
      prototype: URLSearchParams
      new (init?: string | Record<string, string> | string[][]): URLSearchParams
    }
    interface URL {
      hash: string
      host: string
      hostname: string
      href: string
      readonly origin: string
      password: string
      pathname: string
      port: string
      protocol: string
      search: string
      readonly searchParams: URLSearchParams
      username: string
      toString(): string
      toJSON(): string
    }
    var URL: {
      prototype: URL
      new (url: string, base?: string | URL): URL
      canParse(url: string, base?: string): boolean
    }
    function atob(data: string): string
    function btoa(data: string): string
    function structuredClone<T>(value: T): T
    var crypto: {
      readonly subtle: {
        digest(
          algorithm: string | { name: string },
          data: ArrayBufferView | ArrayBuffer,
        ): Promise<ArrayBuffer>
      }
      randomUUID(): string
      getRandomValues<T extends ArrayBufferView>(array: T): T
    }
    var performance: { now(): number }
  }
}

declare module 'claude-code/testing' {
  import type { Args } from 'claude-code';
  import type { Chunk } from 'claude-code';
  import type { ClassicEventName } from 'claude-code';
  import type { ClassicEventOf } from 'claude-code';
  import type { ClassicResultOf } from 'claude-code';
  import type { ClientKeyEvent } from 'claude-code';
  import type { ClientPointerEvent } from 'claude-code';
  import type { Elements } from 'claude-code';
  import type { EventCalls } from 'claude-code';
  import type { EventName } from 'claude-code';
  import type { HookStream } from 'claude-code';
  import type { JsonValue } from 'claude-code';
  import type { On } from 'claude-code';
  import type { PluginOptions } from 'claude-code';
  import type { PressedLink } from 'claude-code';
  import type { Register } from 'claude-code';
  import type { RenderComponent } from 'claude-code';
  import type { RenderElement } from 'claude-code';
  import type { RenderPropsOf } from 'claude-code';
  import type { RenderSurface } from 'claude-code';
  import type { RenderViewport } from 'claude-code';
  import type { ResultOf } from 'claude-code';
  import type { SessionAppendInput } from 'claude-code';
  import type { StreamingEventName } from 'claude-code';
  import type { Tier } from 'claude-code';
  import type { UiInputArgument } from 'claude-code';
  import type { UiInputResult } from 'claude-code';
  import type { UiPressResult } from 'claude-code';
  import type { UiSelectResult } from 'claude-code';

  export type AsymmetricMatcher = {
      readonly text: string;
  };

  export type AsyncMatchers = {
      [K in keyof Matchers]: (...args: Parameters<Matchers[K]>) => Promise<void>;
  };

  export type ClassicEvent = Exclude<ClassicEventName, 'classic.PreToolUse'> extends `classic.${infer E}` ? E : never;

  export type ClassicFields<E extends ClassicEvent> = Omit<ClassicEventOf[`classic.${E}`], 'hook_event_name' | 'session_id' | 'transcript_path' | 'cwd'> & Partial<Pick<ClassicEventOf[`classic.${E}`], 'session_id' | 'transcript_path' | 'cwd'>>;

  export type ClientScope = {
      in?: string;
  };

  export type Constructor = abstract new (...args: never[]) => unknown;

  export const describe: (name: string, body: () => void) => void;

  export type ElementOfAct = {
      input: 'Input';
      select: 'Select';
      key: 'Client';
      pointer: 'Client';
      post: 'Client';
      advance: 'Client';
      resize: 'Client';
  };

  export type ElementQuery = {
      type?: string;
      key?: string;
      text?: string | RegExp;
      in?: string;
  };

  export type Engine = {
      [N in keyof EventCalls]: N extends 'ui' ? EngineNoun<N> & EnginePress & EngineInput & EngineSelect & EngineMount : EngineNoun<N>;
  } & {
      classic: EngineClassic;
  };

  export type EngineCall<E extends EventName> = E extends StreamingEventName ? (e: Args<E>) => HookStream<Chunk<E>, ResultOf[E]> : (e: Args<E>) => Promise<ResultOf[E]>;

  export type EngineClassic = {
      [E in ClassicEvent]: (e: ClassicFields<E>) => Promise<ClassicResultOf[`classic.${E}`]>;
  };

  export type EngineInput = {
      input: (target: InputTarget) => Promise<UiInputResult | undefined>;
  };

  export type EngineMount = {
      mount: <P extends RenderSurface, C extends RenderComponent>(target: MountTarget<P, C>) => Promise<Mounted<P, C>>;
  };

  export type EngineNoun<N extends keyof EventCalls> = {
      [V in EngineNounEvent<N>]: `${N}.${V}` extends 'tool.call' | 'ui.render' ? EventCalls[N][V] : EngineCall<`${N}.${V}` & EventName>;
  };

  export type EngineNounEvent<N extends keyof EventCalls> = Exclude<keyof EventCalls[N] & string, `${N}.resolve` extends 'ui.resolve' ? 'resolve' : never>;

  export type EnginePress = {
      press: (target: PressTarget) => Promise<UiPressResult | undefined>;
  };

  export type EngineSelect = {
      select: (target: SelectTarget) => Promise<UiSelectResult | undefined>;
  };

  export type Expect = Expecting & Matching;

  export const expect: Expect;

  export type Expectation = Negatable<Matchers> & {
      resolves: Negatable<AsyncMatchers>;
      rejects: Negatable<AsyncMatchers>;
  };

  export type Expecting = (received: unknown, message?: string) => Expectation;

  export type FoundElement = {
      type: string;
      key: string | undefined;
      props: Record<string, unknown>;
      text: string;
      children: unknown[];
  };

  export type InputTarget = {
      plugin: string;
      key: string;
      text: string;
      kind?: UiInputArgument['kind'];
      requestId?: string;
      surface?: RenderSurface;
  };

  export type Matchers = {
      toBe: (expected: unknown) => void;
      toEqual: (expected: unknown) => void;
      toStrictEqual: (expected: unknown) => void;
      toMatchObject: (expected: object) => void;
      toContain: (item: unknown) => void;
      toContainEqual: (item: unknown) => void;
      toHaveLength: (length: number) => void;
      toHaveProperty: (path: string | readonly string[], value?: unknown) => void;
      toBeUndefined: () => void;
      toBeDefined: () => void;
      toBeNull: () => void;
      toBeTruthy: () => void;
      toBeFalsy: () => void;
      toBeNaN: () => void;
      toBeGreaterThan: (bound: number | bigint) => void;
      toBeGreaterThanOrEqual: (bound: number | bigint) => void;
      toBeLessThan: (bound: number | bigint) => void;
      toBeLessThanOrEqual: (bound: number | bigint) => void;
      toMatch: (pattern: string | RegExp) => void;
      toStartWith: (prefix: string) => void;
      toEndWith: (suffix: string) => void;
      toBeInstanceOf: (expected: Constructor) => void;
      toThrow: (expected?: ThrowExpectation) => void;
  };

  export type Matching = {
      any: (expected: Constructor) => AsymmetricMatcher;
      anything: () => AsymmetricMatcher;
      stringContaining: (text: string) => AsymmetricMatcher;
      stringMatching: (pattern: string | RegExp) => AsymmetricMatcher;
      objectContaining: (shape: object) => AsymmetricMatcher;
      arrayContaining: (items: readonly unknown[]) => AsymmetricMatcher;
  };

  export type Mock = {
      clock: (on: On, options?: MockClockOptions) => MockClock;
      store: (on: On, entries?: Readonly<Record<string, unknown>>) => void;
      env: (on: On, variables: Readonly<Record<string, string>>) => void;
      session: (on: On) => MockSession;
  };

  export const mock: Mock;

  export type MockClock = {
      now: () => number;
      advance: (ms: number) => Promise<void>;
      set: (ms: number) => Promise<void>;
      settle: () => Promise<void>;
      sleep: (ms: number) => Promise<void>;
  };

  export type MockClockOptions = {
      now?: number;
  };

  export type MockSession = {
      appended: () => readonly SessionAppendInput[];
  };

  export type Mounted<P extends RenderSurface = RenderSurface, C extends RenderComponent = RenderComponent> = {
      [K in keyof MountedMembers<P, C> as K extends keyof ElementOfAct ? ElementOfAct[K] extends keyof Elements[P] ? K : never : K]: MountedMembers<P, C>[K];
  };

  export type MountedMembers<P extends RenderSurface, C extends RenderComponent = RenderComponent> = {
      readonly surface: P;
      drawn: (scope?: ClientScope) => Promise<RenderElement>;
      find: (query: ElementQuery) => Promise<FoundElement | undefined>;
      findAll: (query: ElementQuery) => Promise<FoundElement[]>;
      press: (target: MountPressTarget) => Promise<UiPressResult | undefined>;
      input: (target: MountInputTarget) => Promise<UiInputResult | undefined>;
      select: (target: MountSelectTarget) => Promise<UiSelectResult | undefined>;
      key: (event: MountKeyEvent) => Promise<void>;
      pointer: (event: MountPointerEvent) => Promise<void>;
      post: (data: JsonValue, scope?: ClientScope) => Promise<void>;
      advance: (ms: number) => Promise<void>;
      resize: (size: MountResizeTarget) => Promise<void>;
      redraw: (props?: RenderPropsOf[C]) => Promise<void>;
      unmount: () => Promise<void>;
  };

  export type MountInputTarget = {
      key: string;
      text: string;
      kind?: UiInputArgument['kind'];
      plugin?: string;
  };

  export type MountKeyEvent = ClientKeyEvent & ClientScope;

  export type MountPointerEvent = ClientPointerEvent & ClientScope;

  export type MountPressTarget = {
      key: string;
      plugin?: string;
      link?: PressedLink;
  };

  export type MountResizeTarget = {
      columns: number;
      rows: number;
      in?: string;
  };

  export type MountSelectTarget = {
      key: string;
      value: string;
      plugin?: string;
  };

  export type MountTarget<P extends RenderSurface = RenderSurface, C extends RenderComponent = RenderComponent> = {
      plugin: string;
      surface: P;
      component: C;
      props: RenderPropsOf[C];
      requestId?: string;
      viewport?: RenderViewport;
  };

  export type Negatable<M> = M & {
      not: M;
  };

  export type Plugin = {
      name: string;
      tier?: PluginTier;
      register: Register;
  };

  export type PluginTier = Exclude<Tier, 'core'>;

  export type PressTarget = {
      plugin: string;
      key: string;
      requestId?: string;
      surface?: RenderSurface;
      link?: PressedLink;
  };

  export type SelectTarget = {
      plugin: string;
      key: string;
      value: string;
      requestId?: string;
      surface?: RenderSurface;
  };

  export const test: (name: string, ...rest: TestRest) => void;

  export type TestBody = ($: Engine, on: On) => unknown;

  export type TestOptions = {
      plugins?: readonly Plugin[];
      timeoutMs?: number;
      options?: PluginOptions;
  };

  export type TestRest = readonly [body: TestBody] | readonly [options: TestOptions, body: TestBody];

  export type ThrowExpectation = string | RegExp | Constructor | WithMessage;

  export const tier: (tier: PluginTier) => void;

  export type WithMessage = {
      message: string;
  };
}

