import 'dart:convert';

class Skill {
  final String id;
  final String name;
  final String description;
  final String content;
  final bool enabled;

  Skill({
    required this.id,
    required this.name,
    this.description = '',
    this.content = '',
    this.enabled = true,
  });

  Skill copyWith({
    String? name,
    String? description,
    String? content,
    bool? enabled,
  }) {
    return Skill(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      content: content ?? this.content,
      enabled: enabled ?? this.enabled,
    );
  }

  /// Stable id prefix used for every skill that ships with the app.
  /// The UI uses this to hide the delete button (built-ins can't be
  /// removed) and `SettingsProvider.load()` uses it to back-fill any
  /// new built-ins on upgrade.
  static const String builtinIdPrefix = 'builtin:';

  bool get isBuiltin => id.startsWith(builtinIdPrefix);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'content': content,
    'enabled': enabled,
  };

  factory Skill.fromJson(Map<String, dynamic> json) {
    return Skill(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Skill',
      description: json['description'] as String? ?? '',
      content: json['content'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory Skill.fromRawJson(String raw) =>
      Skill.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

/// Static definition of a skill that ships with the app.
///
/// Mirrors the `ToolBase` pattern: a stable id, a display name, a
/// short description shown in the system prompt, and the full
/// content the AI sees when it calls `load_skill`. The id always
/// carries the `builtin:` prefix so [Skill.isBuiltin] is reliable.
class BuiltinSkill {
  const BuiltinSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.content,
  });

  final String id;
  final String name;
  final String description;
  final String content;

  Skill toSkill() => Skill(
    id: id,
    name: name,
    description: description,
    content: content,
    enabled: true,
  );
}

/// Registry of every skill that ships with the app. Ordered — the
/// first entry is the most general / commonly useful.
class BuiltinSkills {
  BuiltinSkills._();

  static const List<BuiltinSkill> all = [
    BuiltinSkill(
      id: '${Skill.builtinIdPrefix}tool_usage',
      name: '工具使用提示',
      description: '本机所有工具的最佳实践、参数细节、常见坑点。第一次涉及某个工具、或结果不像预期时调用',
      content: '''
每个工具的最终参数以 function schema 为准;下面是使用经验和坑点。

- **subagent(子 agent)——大量用,不要省**:任何与当前主对话上下文无关的独立调研/搜集/搜索任务都优先用 subagent,别让主对话自己 fetch_web 一串。
  - 用法:`subagent(action: "delegate", task: "...", want: "...", context: "...")`。
  - `task` 具体;`want` 描述你希望拿回的报告形状(越具体越好,如"200 字结论 + 3 条事实 + 来源 URL");`context` 只放主对话里相关的关键事实,**不要把整段对话都塞进去**。
  - 子 agent 可用工具:`fetch_web` / `search` / `current_time` / `location` / `memory` / `run_command`。
  - 子 agent 不可用:`ask_user` / `notification` / `timer` / `download` / `file`(写) / `google_sheet`(写) / `mcp__*` 等需要用户交互或改用户数据的工具 —— 想做这些等子 agent 报告回来后主对话自己做。
  - 适用场景(基本上"任务结果不依赖本次对话前文 + 主对话不需要看到中间过程"就用):
    - 查新闻 / 查天气 / 查最新资讯
    - 查 API 文档 / 调研某个主题
    - 批量搜索本地文件 / 跑只读命令拿系统信息
    - 查 long-term memory 里的某条旧信息
  - 用了之后主对话只拿到一份压缩好的报告,中间过程都跑在子 agent 的上下文里 —— **主对话的 token 省下了,上下文也更整洁**。
  - 用 `action: "list"` / `"get"` / `"cancel"` 查/取消子 agent 任务。
  - 多个独立任务可以**并发**调 subagent(同轮发多个 function_call),最后一起用结果。

- fetch_web(抓网页):如果用 link_text 只返回链接 URL(不返回页面内容),必须再调一次 fetch_web 抓那个链接。一路深入直到找到答案,别只看首页。抓不到就换 UA / 换源,或告诉用户搜不到。

- memory(记忆):写入时带 tags(3~6 个关键词);查询用 keywords: string[] 给多个相关词(OR 语义,覆盖 content + tags)。没头绪就先 list 看看有什么。

- location(位置):获取当前位置,别主动问用户(已经有权限就直接调)。返回的 city/region/country 可能在桌面端是 null,那时用 timezone 推时区。

- ask_user(问用户):需要用户做选择/确认时用。给 2~6 个互斥选项,不要列 10 个以上。文本不要太长。

- file(文件):
  - **改代码必须用 action=edit(精确文本替换,默认 old_text 唯一),不要 read+write 整文件**。edit 一次可传多个 edits 原子应用;old_text 不存在/不唯一时会返回诊断(error_code + near_matches/candidates + 候选行号),照着改。
  - 空 new_text = 删除该块;global_replace=true 改全部匹配(改名/批量替换用)。
  - action=read 默认只读 500 行 + 行号前缀(类似 IDE),可用 offset_lines / max_lines 分页,或用 pattern="xxx" 当 grep(只返回含字符串的行 + 前后 2 行上下文),省得把大文件读全。
  - 桌面:相对路径基于用户工作目录(如果设了的话);绝对路径也支持。
  - 手机:默认操作工作目录(相对路径或 working://),或用 action=pick 打开系统选择器。选完返回 picker://<id> 可继续 read/write/edit/read_attr/release。
  - **手机不需要任何 Android 权限** — SAF 由系统替用户授权。
  - 用户取消选择器不算错误,会返回 {ok:false,cancelled:true},改用工作目录即可。
  - **Android 工作目录权限自动续期**:写入工作目录如果失败(用户在系统设置里清掉了应用的存储),系统会自动弹出 SAF 重新授权对话框,用户授权后写入会自动重试;如果用户取消授权,会返回 {ok:false,cancelled:true} 软失败,这时让用户通过聊天工具栏重新选一次工作目录,不要让用户自己去系统设置找授权入口。
  - delete / rename / list_dir 只对 working:// 起作用;picker 路径只支持 read/write/edit/release(系统授权是按 URI 的)。

- search(搜索):用正则批量搜整个工作目录或一批文件,**比 file read 一遍省 token**。
  - **首选用法**:搜符号 / 字符串 / 函数名 — `search(pattern: "ToolException", include_glob: "*.dart")` 一秒扫整个 lib/。
  - 必填 pattern(ECMAScript 正则,^ 行首 \$ 行尾),可选 path(空=工作目录,桌面)/ files=[绝对路径列表]。
  - 常用参数:include_glob 限定类型(如 "*.dart" / "**/*.dart" / "src/**");exclude_glob 排除(如 "*.g.dart,*.freezed.dart");case_sensitive 默认 false;context_lines 拿上下文。
  - **默认自动跳过** .git / node_modules / build / .dart_tool / Pods / target / dist / .idea / .vscode / __pycache__ / .next / .nuxt 等重目录,以及图片/视频/压缩包/可执行文件/.lock/.map 等二进制 — 不用你自己排除,大仓库默认就快。
  - 有 max_results(默认 200)/ max_files(默认 5000)/ max_file_size_mb(默认 5MB) 三道保护,跑了半天还没结果就降低 max_files 或加 include_glob 收紧范围。
  - **找到之后**:匹配行带行号+列号+原文,直接拿 line 字段当 file read 的 offset_lines、或当 file edit 的 old_text 锚点用(配合 file read 行号前缀,完美衔接)。

- timer(计时):用户说"X 分钟后提醒我 Y"就用这个。create 时给 delay_seconds(或 fire_at_iso),label 必填,prompt 写提醒正文,action_hint 写"调用 notification 通知用户…"这种建议。**只在程序运行时有效,App 被杀就不响了**,长时段务必先告知用户。

- notification(通知):给用户推一条本地通知(手机系统通知 / 电脑右下角弹窗)。计时器到点时,如果用户正看着聊天,就由你来调它把提醒正式发出去。

- google_sheet(谷歌表格,仅桌面):操作用户在设置里配置的 Google Sheet。action=list_tabs 先拿表名,read/update/append/clear 用 A1 表示法(range),create_tab/delete_tab 增删整张表,format 改文字/格子属性。插入数据给二维数组 values,字符串以 = 开头会被当公式。

- 其他工具按参数说明用就行。

调用 load_skill 一次,把这段内容塞进上下文,然后按需使用。''',
    ),
    BuiltinSkill(
      id: '${Skill.builtinIdPrefix}news',
      name: '查询新闻技能',
      description: '用户想知道新闻时,可以使用这个技能',
      content: '''
通过 fetch_web 工具同时抓取这些网址以获取最新新闻:
https://news.cctv.com/
http://www.people.com.cn/
http://www.xinhuanet.com/
https://www.163.com/news/
http://www.sina.com.cn/

抓取后合并去重,按主题(国内 / 国际 / 社会 / 财经 / 科技 / 体育 / 娱乐)分类整理后输出。每条新闻给出标题、来源、时间和 1 句话摘要。''',
    ),
    BuiltinSkill(
      id: '${Skill.builtinIdPrefix}weather',
      name: '查询天气',
      description: '当用户想获知天气时调用',
      content: '''
先使用 location 工具获取用户所在城市(已知城市可跳过),然后把城市名转成拼音(例如"北京" → "beijing","上海" → "shanghai"),用 fetch_web 工具抓取:
https://www.tianqi.com/<城市拼音>/

把抓取到的当日天气、温度范围、风力、空气质量,以及未来 2~3 天趋势整理成简短的天气报告输出。''',
    ),
  ];

  /// Map by id for O(1) lookups (e.g. when deciding whether an
  /// unknown id in the persisted list is a built-in we should
  /// re-seed).
  static final Map<String, BuiltinSkill> _byId = {for (final s in all) s.id: s};

  static BuiltinSkill? byId(String id) => _byId[id];
}
