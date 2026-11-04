local M={}
function M.set(s,node)
    s.selected=node;s.shared_node_version=1
    for _,p in pairs(s.profiles or {}) do p.node=node end
    return node
end
function M.reconcile(s,nodes,active)
    local known={['privacy-auto']=true}
    for _,n in ipairs(nodes)do known[n.tag]=true end
    local selected=known[s.selected] and s.selected or 'privacy-auto'
    if s.shared_node_version~=1 then
        -- Old files have no reliable last-change timestamp. Preserve the sole
        -- active device's explicit choice; with several, keep the page default.
        local count,choice=0,nil
        for mac in pairs(active or {})do
            local p=(s.profiles or {})[mac]
            if p then count=count+1;choice=known[p.node] and p.node or selected end
        end
        if count==1 then selected=choice end
    end
    return M.set(s,selected)
end
return M
