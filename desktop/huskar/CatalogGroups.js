.pragma library

function entryLabel(group, item) {
    if (group.name === "护盾力场") return item.name
    if (item.name === group.name) return "本体参数"
    if (item.name.indexOf(group.name) === 0) {
        const suffix = item.name.slice(group.name.length).replace(/^[\s:：·-]+/, "")
        if (suffix.length) return suffix
    }
    return item.name
}

// Prefer explicit parent metadata; only infer colon-separated variants when the
// exact parent also exists. Similar words alone must not merge unrelated units.
function build(items, full, tab) {
    if (["Primary", "Secondary", "Support", "Throwables"].indexOf(tab) >= 0) return []
    const names = {}
    for (const item of full) names[item.name] = item
    const result = [], byKey = {}
    for (const item of full) {
        let parents = item.groups || []
        if (!parents.length) {
            const at = item.name.search(/[:：]/)
            const base = at > 0 ? item.name.slice(0, at).trim() : ""
            const root = names[base]
            parents = [{id: String(root ? root.id : item.id), name: root ? root.name : item.name}]
        }
        for (const parent of parents) {
            const key = String(parent.id)
            let group = byKey[key]
            if (!group) {group = {id:key, name:parent.name, entries:[], changed:false}; byKey[key]=group; result.push(group)}
            if (!group.entries.some(x=>x.id===item.id)) group.entries.push(item)
            group.changed = group.changed || item.changed
        }
    }
    const matched = {}
    for (const item of items) matched[String(item.id)] = true
    const visible = result.filter(x=>x.entries.some(item=>matched[String(item.id)]))
    return visible.some(x=>x.entries.length>1) ? visible : []
}
