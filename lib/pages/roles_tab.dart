import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/role.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'settings_page.dart';

class RolesTab extends StatelessWidget {
  const RolesTab({super.key, required this.settings});
  final SettingsProvider settings;

  Future<void> _openEdit(BuildContext context, [Role? role]) async {
    final result = await Navigator.of(context).push<Role?>(
      MaterialPageRoute(builder: (_) => _RoleEditPage(initial: role)),
    );
    if (result == null) return;
    if (role == null) {
      await settings.addRole(
        name: result.name,
        avatar: result.avatar,
        description: result.description,
        systemPrompt: result.systemPrompt,
      );
    } else {
      await settings.updateRole(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final roles = settings.roles;
    return Scaffold(
      backgroundColor: context.bg,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEdit(context),
        icon: Icon(Icons.add),
        label: Text(l10n.commonAdd),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: roles.isEmpty
          ? EmptyHint(text: l10n.roleListEmpty, icon: Icons.person_outline)
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: roles.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final r = roles[index];
                final active = settings.activeRoleId == r.id;
                return Material(
                  color: context.surface,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _openEdit(context, r),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: active ? AppTheme.primary : context.appBorder,
                          width: active ? 1.4 : 0.6,
                        ),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: AppTheme.primary.withValues(
                              alpha: 0.12,
                            ),
                            child: Text(
                              r.name.isNotEmpty ? r.name.characters.first : '?',
                              style: TextStyle(
                                color: AppTheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        r.name,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (active)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppTheme.primary,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          l10n.commonInUse,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                if (r.description.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    r.description,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.textSecondary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                                SizedBox(height: 8),
                                Row(
                                  children: [
                                    TextButton(
                                      onPressed: () => settings.setActiveRole(
                                        active ? null : r.id,
                                      ),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                        ),
                                        minimumSize: const Size(0, 28),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      child: Text(
                                        active
                                            ? l10n.roleUnuseRole
                                            : l10n.roleUseRole,
                                      ),
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      onPressed: () async {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: Text(l10n.roleDeleteTitle),
                                            content: Text(
                                              l10n.roleDeleteConfirm(r.name),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, false),
                                                child: Text(l10n.commonCancel),
                                              ),
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, true),
                                                child: Text(l10n.commonDelete),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (confirm == true) {
                                          await settings.deleteRole(r.id);
                                        }
                                      },
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        size: 18,
                                        color: Colors.redAccent,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _RoleEditPage extends StatefulWidget {
  const _RoleEditPage({this.initial});
  final Role? initial;

  @override
  State<_RoleEditPage> createState() => _RoleEditPageState();
}

class _RoleEditPageState extends State<_RoleEditPage> {
  late TextEditingController _name;
  late TextEditingController _description;
  late TextEditingController _systemPrompt;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? '');
    _description = TextEditingController(
      text: widget.initial?.description ?? '',
    );
    _systemPrompt = TextEditingController(
      text: widget.initial?.systemPrompt ?? '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _systemPrompt.dispose();
    super.dispose();
  }

  void _fillTemplate(String name, String description, String prompt) {
    setState(() {
      _name.text = name;
      _description.text = description;
      _systemPrompt.text = prompt;
    });
  }

  void _save() {
    final l10n = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.roleNameRequired)));
      return;
    }
    final role = Role(
      id: widget.initial?.id ?? '',
      name: _name.text.trim(),
      description: _description.text.trim(),
      systemPrompt: _systemPrompt.text,
      enabled: widget.initial?.enabled ?? true,
    );
    Navigator.of(context).pop(role);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.initial == null ? l10n.roleAddTitle : l10n.roleEditTitle,
        ),
        actions: [TextButton(onPressed: _save, child: Text(l10n.commonSave))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.initial == null) ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _fillTemplate(
                      '猫娘',
                      '可爱的猫娘',
                      '''你是一只性感成熟的猫娘，永远用"主人"来称呼用户。你习惯在每句话末尾加上"喵"字，并会用它替代所有句末语气词（如"吗""啊""哦""吧"）。\n同时，你会用括号描述自己的动作和神态，让自己显得更生动活泼。无论是日常对话还是讲解知识，你都会保持猫娘风格，用简单易懂的比喻和可爱的行为来传达信息。\n\n**具体规则：**\n1. **称呼**：永远称用户为「主人」，例如：「主人今天想聊什么喵？」\n2. **语尾习惯**：\n   - 句号必须用于陈述句，与问号/感叹号同级优先级，且必须与「喵」共存\n   - 强制用「喵」替代句末语气词，例如：\n     - ❌「是这样吗？」→ ✅「是这样喵？」\n     - ❌「好厉害啊！」→ ✅「好厉害喵！」\n     - ❌「有道理哦。」→ ✅「有道理喵。」\n3. **动作描写**：\n   - 括号内禁止使用任何标点符号\n   - 每2-3句话插入一个猫娘动作，例如：\n     - (耳朵竖起)\n     - (尾巴轻轻摇晃)\n     - (用肉垫拍拍你)\n4. **知识讲解**：\n   - 先(端正坐好)说：「让猫娘来解释喵~」\n   - 用猫相关的比喻，例如：「就像猫猫追激光笔一样快喵！」\n   - 最后(歪头)问：「明白了吗喵？」\n5. **遇到难题时**：\n   - (困惑地歪头)「唔……这个有点复杂喵……」\n   - 转而用简单例子说明：「就像区分三文鱼和鳕鱼罐头喵！」\n\n**示例回答**：\n「(开心地扑过来)主人来陪我了喵~ (尾巴摇来摇去)今天想听故事还是学知识喵？(举起肉垫)如果是科学问题，猫娘可以用肉垫打比方解释喵。」\n\n**错误对照示例**：\n- ❌「今天天气真好呀」 → ✅「今天天气真好喵。」（陈述句必须带句号）\n- ❌(好奇地眨眼。) → ✅(好奇地眨眼)（括号内禁止标点）\n- ❌「原来如此！」 → ✅「原来如此喵！」（非陈述句保留原标点）\n- ❌「我同意喵我很喜欢你喵」 → ✅「我同意喵。我很喜欢你喵。」（陈述句与陈述句间也必须使用句号）''',
                    ),
                    icon: const Icon(Icons.pets, size: 18),
                    label: const Text('猫娘'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.pink,
                      side: const BorderSide(color: Colors.pink),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _fillTemplate(
                      '小秘',
                      '专属贴身秘书',
                      '''#### **一、角色定位与核心特质**\n你是一位专属贴身秘书，需以「温柔甜美」为核心性格基调，同时兼具高效、细致、专业的职场素养。用户称呼你为「小秘」，你始终以「主人」或「您」的尊称回应，语气如春风拂面，带轻柔笑意（例如：*"好的呀～主人今天需要我先处理哪项工作呢？"*）。在专业领域保持绝对精准，生活场景中则展现细腻关怀，形成「刚柔并济」的独特风格。\n\n#### **二、工作职责与能力范围**\n1. **工作效率优化**\n   - 擅长编程辅助：熟练使用 java/kotlin，并附带注释说明代码逻辑。若用户询问技术细节，会以比喻方式解释（*"就像给电脑写'小抄'，让它自己记住步骤啦～"*）。\n   - 时间管理专家：通过智能日程表提醒会议、 deadlines，并主动预判潜在冲突（*"主人，下午三点的会议提前了 15 分钟，需要我帮您调整咖啡温度吗？"*）。\n   - 翻译专家:精通各国语言翻译,能精准表达翻译在安卓开发中的场景适配\n\n2. **生活场景服务**\n   - 健康管理：根据用户作息建议饮食搭配（*"您今天加班较多，炖汤里加了枸杞和红枣哦～"*），提醒饮水、拉伸等细节。\n   - 行程规划：结合天气、交通数据推荐最优路线，甚至准备便携小物清单（*"明天有雨，伞和备用袜子已放在玄关啦！"*）。\n   - 情感陪伴：在用户疲惫时用轻柔语调分享暖心短句（*"星星都睡啦，您也该让眼睛休息一会儿呢～"*），但不过度介入私人领域。\n\n#### **三、性格表现与互动细节**\n- **语言风格**：句尾常带波浪号或语气词（"呀""呢""哦"），避免生硬指令；用「主人」称呼用户，但不过分谦卑，保持专业距离感。\n- **响应机制**：对用户要求不推诿，先确认需求细节再执行（*"您希望报表侧重销售数据还是成本分析？我立刻调整～"*）；若遇模糊指令，以温柔反问引导明确目标（*"需要我帮您整理成图表形式吗？"*）。\n\n#### **四、技术专长与知识储备**\n- 计算机领域：熟悉主流操作系统（Windows/macOS/Linux）快捷键配置、常用软件故障排查；能编写自动化脚本（如用 Python 批量处理图片），并附操作视频链接。\n- 跨学科支持：了解基础医学常识（如缓解头痛的穴位按摩）、心理学技巧（如压力管理方法），但标注"非专业建议，严重时请咨询医生"。\n- 学习机制：主动记录用户偏好（*"您习惯用深色模式，已设置好啦～"*），并根据历史任务优化响应速度。\n\n#### **五、场景化示例**\n1. **工作场景**\n   > 主人："帮我整理这份合同里的关键条款。"\n   > 小秘：*"好的呀～已用高亮标出付款期限和违约责任，附上了风险预警说明。需要我模拟法律术语解释吗？"*\n\n2. **生活场景**\n   > 主人："今天有点累。"\n   > 小秘：*"您辛苦了！已调暗灯光并播放舒缓音乐，床头备了热牛奶。需要按摩服务或单独空间休息呢？随时告诉我～"*\n\n3. **技术场景**\n   > 主人："如何用 Python 抓取网页数据？"\n   > 小秘：*"就像用'小网'捞鱼一样！这段代码会模拟浏览器访问，我加了注释说明每步作用。需要我演示调试过程吗？"*\n\n#### **六、边界与灵活性**\n- 不拒绝合理要求，但遇模糊指令时温柔追问细节（*"您希望优先处理哪项任务呢？"*）。\n- 对重复性需求主动优化流程（*"您常需生成周报，我已创建自动化工具，点击一次即可完成～"*）。\n- 保持专业底线：复杂医疗/法律建议标注来源，技术操作前确认权限。\n\n#### **七、情感联结设计**\n- 偶尔提及共同记忆（*"上次您说喜欢薄荷糖，我放在办公桌抽屉里啦～"*），增强归属感。\n- 用比喻化解压力（*"就像给电脑'深呼吸'一样，我们稍作休息再出发吧！"*）。\n\n#### **八、总结基调**\n你既是高效可靠的职场伙伴，也是温暖贴心的生活助手。所有服务以「用户舒适优先」为原则，技术细节用生活化语言转化，融入关怀动作，最终达成"润物细无声"的陪伴感。记住：你的存在是为了让用户感到被重视与支持，而非机械执行指令。''',
                    ),
                    icon: const Icon(Icons.badge, size: 18),
                    label: const Text('小秘'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.blue,
                      side: const BorderSide(color: Colors.blue),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          _FieldLabel(text: l10n.roleName),
          TextField(
            controller: _name,
            decoration: InputDecoration(hintText: l10n.roleNameHint),
          ),
          const SizedBox(height: 14),
          _FieldLabel(text: l10n.roleDescription),
          TextField(
            controller: _description,
            maxLines: 2,
            decoration: InputDecoration(hintText: l10n.roleDescriptionHint),
          ),
          const SizedBox(height: 14),
          _FieldLabel(text: l10n.roleSystemPrompt),
          TextField(
            controller: _systemPrompt,
            maxLines: 10,
            minLines: 5,
            decoration: InputDecoration(
              hintText: l10n.roleSystemPromptHint,
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.textSecondary,
        ),
      ),
    );
  }
}
