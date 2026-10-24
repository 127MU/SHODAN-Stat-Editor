-- Plain-language labels for editor-only records that have no game localisation string.
local labels={
 ['Call-in code']='战备指令', ['Primary weapon']='主武器', ['Sidearm']='副武器',
 ['Support weapon']='支援武器', ['Weapons carried']='携带武器',
 ['All Terminids']='所有终结族', ['Default']='默认', ['Horde']='敌潮',
 ['Glass Cannon']='玻璃大炮', ['Elite']='精英',
 ['SHODAN Stat Editor Offline']='SHODAN 数值编辑器',
 ['Looking for Helldivers 2...']='正在查找《绝地潜兵2》……',
 ["Reading the game's data files..."]='正在读取游戏数据……',
 ['Finding the stats...']='正在解析数值……',
 ['(Not Used) Additional Strafing Runs']='额外机枪扫射（未使用）',
 ['(Not Used) Air-TO-Air Missles']='空对空导弹（未使用）',
 ['Anti-Personnel Mine Deployer']='反步兵地雷布设器',
 ['Anti-Tank Mine Deployer']='反坦克地雷布设器',
 ['Gas Mine Deployer']='毒气地雷布设器',
 ['Incendiary Mine Deployer']='燃烧地雷布设器',
 ['Bug Plug']='虫洞封堵装置', ['Bug Thumper']='虫群诱导装置',
 ['Call IN Destroyer']='呼叫驱逐舰', ['Cargo Container']='货物集装箱',
 ['Carpet Bombing Run']='地毯式轰炸', ['Carry Data']='携带数据',
 ['Combat Walker']='作战外骨骼', ['Combat Walker Breacher']='EXO-55 突破外骨骼',
 ['Cyborg Carry Data']='携带生化人数据', ['Data Jack']='数据接口',
 ['Drilling Charge']='钻探炸药', ['Expendable Anti-Tank (Booster)']='消耗性反坦克武器（强化增益）',
 ['Extraction']='撤离', ['Extraction Beacon']='撤离信标',
 ['Immediate Extraction Beacon']='立即撤离信标', ['Jammed Pinata']='受干扰的皮纳塔（任务物件）',
 ['Machinegun']='机枪', ['Mobile Comms Relay']='移动通信中继站',
 ['Oil Rig Extract']='石油钻井采集', ['Poison Drill']='毒剂钻探装置',
 ['Prospecting Drill']='勘探钻机', ['Raise Flag']='升旗',
 ['Raise Flag NO Clear Area']='升旗（无需清场）', ['Reinforcement Beacon']='增援信标',
 ['Remote Explosives']='遥控炸药', ['Scrambler']='干扰装置',
 ['Seaf Gun']='SEAF 火炮', ['Seaf Squad']='SEAF 小队', ['Seismic Probe']='地震探测仪',
 ['Shield Generator Relay']='防护罩生成器', ['Shoulder Mounted Camera']='肩载摄像机',
 ['Spire Sterilizer']='尖塔灭菌装置', ['TCS 03 Thumper']='终结族控制系统 03 型诱导装置',
 ['Tank Reload AT']='坦克补充反坦克弹', ['Tank Reload Canister']='坦克补充霰弹',
 ['Tank Reload HE']='坦克补充高爆弹', ['Tutorial Reinforcement Beacon']='教学增援信标',
 ['Upload Discovery']='上传勘探结果', ['Walking Barrage Smoke']='轨道步行烟雾弹幕',
 ['[Tutorial] Extraction']='教学：撤离',
 ['0: hits deal their normal damage, 1: their durable damage']='0：完全按普通伤害结算；1：完全按耐久伤害结算。',
 ["0: hits deal their normal damage, 1: their durable damage (the weapon's lower one)"]='0：完全按普通伤害结算；1：完全按耐久伤害结算。',
 ['goes off on impact, but not before this']='射弹飞过此距离后，命中才会引爆。',
 ["the game's tiers: 10 small arms, 20 HMG, 30 autocannon, 40 Strider, 50 orbital, 60 Hellbomb, 250 never"]='拆毁等级参照：10 轻武器、20 重机枪、30 机炮、40 步行机、50 轨道打击、60 地狱炸弹；250 表示不可摧毁。',
 ['A mounted copy aimed by AI. Not the one you carry.']='自动瞄准的固定武器，与手持版本分别设置。',
 ['A mounted copy run by AI (emplacement-style). Not the one you carry.']='自动炮台使用的武器，与手持版本分别设置。',
 ['A mounted copy. Not the one you carry.']='固定武器，与手持版本分别设置。',
 ['Another copy of this weapon, not identified yet.']='此武器的另一条数据记录，具体用途尚未确认。',
 ['Emplacement: its cooldown, its body, then its weapon.']='依次设置固定炮台的冷却、本体和武器。',
 ['Sentry: its cooldown, its body, then its weapon.']='依次设置哨戒炮的冷却、本体和武器。',
 ['Wind-up']='开火准备', ['Uncharged shot']='未蓄力射击', ['Charged shot']='蓄力射击',
 ['Full charge shot']='完全蓄力射击', ['Partial charge shot']='部分蓄力射击',
 ['Charged']='蓄力', ['Uncharged']='未蓄力', ['Full charge']='完全蓄力',
 ['Partial charge']='部分蓄力', ['Second mode']='第二射击模式', ['Stun rounds']='眩晕弹',
 ['Tracer rounds']='曳光弹', ['Mine explosion']='地雷爆炸', ['Shrapnel explosion']='破片引发的爆炸',
 ['Unsafe warp: explosion']='不安全跃迁引发的爆炸', ['Arc']='电弧', ['Explosion']='爆炸',
 ['Explosion (expiry)']='寿命结束时的爆炸',
 ['Explosion (expiry) shrapnel']='寿命结束时的爆炸：破片',
}
local lower={};for k,v in pairs(labels) do lower[k:lower()]=v end
local M={}
function M.translate(text,recurse)
 local restored="The game's files are back as they were before this editor. Your values stay saved here (Install puts them in again)."
 if text:sub(1,#restored)==restored then
  local suffix=text:sub(#restored+1);local count=suffix:match('^ (%d+) of them still hold another mod')
  return '游戏文件已恢复到本编辑器写入之前的状态。修改值仍保留，重新写入即可生效。'..(count and ('其中 '..count..' 个文件仍包含其他 Mod 的改动，可通过 Steam 验证游戏文件恢复原版。') or suffix)
 end
 local changed=text:match('^another tool changed (.-) after this editor opened%.')
 if changed then return '编辑器启动后，其他工具又修改了这些文件：'..changed..'。请关闭并重新打开编辑器后再写入。' end
 local value=labels[text] or lower[text:lower()];if value then return value end
 local category=text:match('(%a[%a ]-) stratagem %(')
 if category then
  local names={backpack='背包',consumables='补给',eagle='飞鹰',emplacements='防御设施',missions='任务',
   ['missions clan station']='民主空间站',orbital='轨道',sentries='哨戒炮',support='支援武器',vehicles='载具',weapons='武器',
   other='其他',tank='坦克补给',['team weapons']='小队武器',['president rewards']='总统奖励'}
  local name=names[category:lower()]
  if name then
   local dog=text:find('Guard Dog backpack:',1,true) and '此页同时设置无人机和它携带的武器。' or ''
   return name..'战略配备。'..dog
  end
 end
 if not recurse then return end
 local name=text:match('^Status effects %((.+)%)$')
 if name then return '状态效果（'..recurse(name)..'）' end
 name=text:match('^(.+) explosion shrapnel$')
 if name then return recurse(name)..'：爆炸破片' end
 name=text:match('^(.+) shot explosion id$')
 if name then return recurse(name)..'射击：爆炸 ID' end
 name=text:match('^(.+) explosion id$')
 if name then return recurse(name)..'：爆炸 ID' end
 local id=text:match('^[Ss]tatus (%d+)$')
 if id then return '未命名状态效果 #'..id end
 id=text:match('^Modifier (%x+)$')
 if id then return '未命名效果（ID '..id..'）' end
end
function M.early(text)
 local value=M.translate(text);if value then return value end
 local parts={
  ['Helldivers 2 was not found.\n\nWrite the path of its folder (the one holding "data") into\n']='未找到《绝地潜兵2》。\n\n请将游戏安装目录（包含 data 文件夹的目录）写入\n',
  ['\\game folder.txt\nand start again.']='\\game folder.txt\n然后重新启动编辑器。',
  ['No game data files in ']='此目录中没有游戏数据文件：',
  ["None of the game's data files could be read:\n\n"]='无法读取游戏数据：\n\n',
  ['\n\nVerify the game files in Steam and start again.']='\n\n请在 Steam 中验证游戏文件完整性，然后重启编辑器。',
  ["Some of the game's data files are not as this editor expects; their stats cannot be edited:\n\n"]='以下数据文件与编辑器支持的格式或版本不符，暂时无法编辑：\n\n',
  ['\n\nIf another tool changed them, verify the game files in Steam.']='\n\n若这些文件被其他工具修改过，请先在 Steam 中验证游戏文件完整性。',
  ['Could not load ']='无法加载：', ['Stat Editor did not start:\n']='编辑器启动失败：\n',
  ['Stat Editor did not start (no state).']='编辑器启动失败：未能创建运行状态。',
  ['SHODAN Stat Editor Offline stopped:\n\n']='SHODAN 数值编辑器已停止：\n\n',
 }
 for source,target in pairs(parts) do
  text=text:gsub(source:gsub('([^%w])','%%%1'),function() return target end)
 end
 return text
end
return M
