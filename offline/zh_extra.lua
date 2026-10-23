local exact={
 ['STATUS EFFECTS']='状态效果',['EXTRA STRATAGEM']='附加战略配备',['Status effects']='状态效果',['Extra stratagem']='附加战略配备',['Extra stratagem (choice)']='附加战略配备',
 ['Burning']='燃烧',['Heavy burning']='强烈燃烧',['Fire panic']='火焰恐慌',['Flamethrower slow']='喷火器减速',
 ['Stun (small)']='轻度眩晕',['Stun (medium)']='中度眩晕',['Stun (large)']='重度眩晕',
 ['Gas']='毒气',['Gas confusion']='毒气混乱',['Gas (Sterilizer)']='毒气（灭菌器）',['Gas confusion (Sterilizer)']='毒气混乱（灭菌器）',
 ['Regeneration (health/s)']='生命恢复速度（每秒）',['Regeneration delay after damage (s)']='受伤后恢复延迟（秒）',
 ['damaged parts heal; destroyed parts stay destroyed']='受损部件可恢复，已摧毁部件不会复原',
 ['Countdown before delivery (s)']='投送前倒计时（秒）',['Approach distance (m)']='接近距离（米）',
 ['Speed until it has fired (m/s)']='开火前飞行速度（米/秒）',
 ['also in your loadout when you bring this one']='携带此配备时，同时获得所选配备',
 ['goes off on impact, but not before this']='触地引爆，但不会早于此时间',
 ['what each hit applies; the slots go in order']='每次命中施加的效果；按槽位顺序设置',
 ['That would make a loop of extra stratagems.']='附加战略配备不能形成循环链。',
 ["It doesn't take a loadout slot, but the HUD's stratagem list can fill up."]='不占配装槽位，但 HUD 的战略配备列表有显示上限。',
 ["The beacon's countdown before the delivery is sent."]='信标发出后，正式开始投送前的倒计时。',
 ["A hellpod lands this many seconds plus its 4.75 s fall after the beacon, so 0 is the fastest it gets."]='落地还需约 4.75 秒降落时间，倒计时设为 0 时最快。',
 ['Ship upgrades that make support weapons and sentries launch at once skip it (tested).']='令支援武器及哨戒即时发射的飞船升级会跳过此倒计时。',
 ['How far away the jet starts its run. With its speed, it sets how long the Eagle takes to arrive.']='飞机开始接近的距离，与飞行速度共同决定到达时间。',
 ["The beacon's timer still counts down the usual time (tested)."]='信标计时器仍显示通常的倒计时。',
}
local M={}
function M.translate(v)
 if exact[v] then return exact[v] end
 local n=v:match('^Status effect (%d+) %(choice%)$');if n then return '状态效果 '..n end
 local index,per=v:match('^Status effect (%d+) strength per (.+)$')
 if index then return '状态效果 '..index..' 强度（每次'..(per=='hit' and '命中' or '爆炸')..'）' end
 local section=v:match('^Status effects %((.+)%)$');if section then return '状态效果（'..(exact[section] or section)..'）' end
 local applied=v:match('^Applies: (.+)$');if applied then return '施加：'..(exact[applied] or applied=='none' and '无' or applied) end
 local missing=v:match('^Give status effect (%d+) first');if missing then return '请先设置状态效果 '..missing..'。' end
 local clear=v:match('^Clear status effect (%d+) first');if clear then return '请先清除后面的状态效果 '..clear..'。' end
end
return M
