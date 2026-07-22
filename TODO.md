# agent_buddy

Agent Buddy

目标:跨端智能体基座

### 代办事项

#### 已完成


#### BUG修复
- mac 上无法选择工作目录问题， 点击工作目录没有反应。
- mac Google Sheet 工具无法授权问题，无法启动本地服务授权


#### 桌宠开发：
开源桌宠素材下载网站：https://petdex.dev/
下载的素材是  Spritesheet（精灵图）：一张png有角色各种动作。
在 Flutter 中，你可以使用 sprite_sheet 或 flutter_animate 等相关插件 ：flutter_spritesheet_animation: ^1.0.3
只需提供这张大图，并配置好每张小图的宽高（frameWidth/frameHeight）、列数（columns）以及动作对应的帧范围（startFrame - endFrame），
Flutter 就能自动帮你裁剪并播放出流畅的动画了
https://petdex.dev/pets/anya-2 阿尼亚

我需要开发桌面端桌宠功能：
- 在项目设置页增加桌宠tab，放置在角色tab右侧
- 桌宠设置页：顶部开关显示桌宠，还要展示一个链接跳转下载宠物的网址：https://petdex.dev/ ，下方是宠物列表，右下角是新增按钮，可以从文件导入 导入的宠物文件是zip，里面有json和png。
- json里面有桌宠名称和介绍等，展示在列表内，图片是角色精灵图 Spritesheet，宠物文件范例见assets/pet/anya.zip，你解压看看格式。默认内置这个宠物。
- 技术方案可能需要实现flutter多窗体组件，宠物用一个透明窗体展示，精灵动画可以试试 lutter_spritesheet_animation: ^1.0.3
- 桌宠精灵图从上到下的动作是：Idle,Run Right,Run Left,Waving,Jumping,Failed,Waiting,Running,Review;
- 帧数分别是：6，8，8，4，5，8，6，6，6
- 宠物在桌面要置顶展示，可随意拖动，右键弹出菜单可以关闭桌宠，左键点击打开主窗口，向左拖动展示动画：Run Left ， 向右拖动展示动画：Run Right
- 宠物启动出现时展示动作：Waving 播放一次, 默认待机动作 Idle 循环播放, 模型工具执行成功时执行动作：Jump 播放一次，工具失败执行动作：Failed 播放一次.
- 模型思考时执行动作：Waiting 循环播放, 模型流式输出的时候展示动作：Review 循环播放, 用户输入时或者等待用户回答问题时展示动作：Waiting 循环播放.
- 待机动作循环展示，其它动作执行完后回归待机动作，帧率先定为每秒4帧，

- 桌宠功能不能用内置的阿尼亚的pet.json 来定义参数，因为要兼容其它导入的桌宠zip文件，虽然每个文件格式都一致，动作也是一致，重构一下兼容其它桌宠zip文件。
- 没有展示内置的阿尼亚桌宠，桌宠窗体不是无边框的透明窗体，导入其它zip桌宠文件报错，请修复这些问题

#### 未完成
- 后续功能开发方向，桌面的加一个桌宠。做一个真正的AI桌宠。
- 桌面端窗口关闭按钮不再退出程序，而是最小化到状态栏。状态栏图标左键打开主窗口，右键弹出菜单，菜单内有：显示主窗口，退出程序，关闭宠物/打开宠物。

- 怎么处理 word,excel,pdf 文件,
- 怎么解包zip文件,相关的类zip文件,jar,apk等

- 图片bbox检测，返回图片物体bbox:（坐标不用像素，用图片宽高百分比位置，这样图片缩放也能保证位置的准确性）
例子：
```json5
{
  "objects": [
    {
      "label": "猫",
      "confidence": 0.96,
      "bbox": [0.11, 0.18, 0.95, 0.88] // x1,y1左上角 x2,y2右下角图片
    }
  ]
}
```


#### 其它
搜索 skill :
```json5
{
  "url": "https://www.bing.com/search?q=关键词" 
}
```
