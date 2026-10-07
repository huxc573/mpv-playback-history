-- playback_history.lua
-- 播放历史：记住最近播放过的「本地文件」（路径/标题/进度/时长/时间），
-- uosc 控件条按钮 + uosc 风格菜单选择任意条目续播。
--
-- 与 uosc 的对接方式（照抄 uosc_danmaku 的官方姿势）：
--   - 按钮：script-message-to uosc set-button <name> <json>
--   - 菜单：script-message-to uosc open-menu <json>（激活时 uosc 按条目 value 执行命令）
-- 菜单条目 value 用命令数组传索引（不传路径），避免路径里有空格/引号的转义问题。
--
-- 记录策略：
--   - 本地文件与网络流都记；本地按父文件夹分组，网络按「来源」(URL host) 分组，
--     组名可用 source_names 起别名，常见后端（Plex/Jellyfin/Emby）自动识别
--   - 网络记录能否点播由 stream_play 控制（auto=自动判断临时地址则置灰 / always / never），
--     点开后若加载失败会自动停止并提示，绝不让失效 URL 晾在界面上
--   - 本地文件额外记父文件夹（dir），菜单里一键把整目录装入播放列表（换集用）
--   - ⭐只记「真播过」的：进度 >= min_play 秒才入历史；仅被加载、没播的（如 FnTV
--     播放列表启动瞬间先加载上一集）一律不记，从根上杜绝「没看的也进历史」
--   - 落盘时机：每 save_interval 秒 / 暂停时 / 退出时（三重保险，进度丢不了）
--   - 同一路径去重；重播才置顶；上限 max_items 条，JSON 单文件存储
--
-- 续播规则：选中条目 → loadfile；若 mpv 自己（watch_later）没恢复过进度
-- （time-pos < 5s）且记录进度 >= min_resume 且距片尾 > 15s，则 seek 过去。
-- 空启动待命时空格/回车/左键 = 续播最近一条（对齐原 autoload_last 的行为）。

local mp = require 'mp'
local msg = require 'mp.msg'
local opt = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    save_interval = 1800, -- 播放中每隔多少秒把进度写盘（默认 30 分钟）
    min_resume = 30,      -- 记录进度少于这个秒数就不自动续（避免开头误续）
    max_items = 500,      -- 历史上限，超出淘汰最旧的
    min_play = 3,         -- 新建条目所需的最小播放秒数（只加载没播的不入历史）
    idle_prefer_local = true,  -- 空启动续播：最近一条不可续播时，改用最近一条可续播记录
    stream_play = 'auto', -- 网络记录是否可点播：auto(自动判断)/always(全可点)/never(全置灰)
    source_names = '',    -- 网络来源别名：host=名字，逗号分隔（如 192.168.1.9=FnTV,plex.local=Plex）
    file = '',            -- 历史文件路径（留空=~~/playback_history.json）
    list_expand = 'filter', -- 点历史里的本地文件时带出同目录剧集：filter(相似名)/same(同目录全部)/no
}
opt.read_options(o, 'playback_history')

-- 来源别名表（host 小写 → 显示名），供 group_label 用
local SOURCE_NAMES = {}
for pair in tostring(o.source_names or ''):gmatch('[^,;]+') do
    local h, n = pair:match('^%s*([^=]+)%s*=%s*(.-)%s*$')
    if h and n and n ~= '' then SOURCE_NAMES[h:lower()] = n end
end

local HISTORY_FILE = o.file ~= '' and o.file
    or mp.command_native({'expand-path', '~~/playback_history.json'})
msg.info('history file: ' .. tostring(HISTORY_FILE))

local entries = nil            -- {path,title,pos,dur,ts,dir}，最新在前
local pending_resume = nil     -- {path,pos} 等对应文件 file-loaded 时 seek
local deleted_paths = {}       -- 本次会话删掉的路径（防别的实例写盘时复活）
local save_timer = nil         -- 周期写盘定时器（save_interval 可在菜单设置里改）
local hint_mute_until = 0      -- 明确提示后的静默截止时刻（秒）

-- 状态提示统一出口：既弹提示，也把「空格续播」那类提示压后，
-- 免得刚说完「地址已失效」就被随后到来的 idle 提示覆盖（uosc 的 OSD 后到先得）。
local function osd(text, secs)
    secs = secs or 3
    hint_mute_until = mp.get_time() + secs + 1
    mp.osd_message(text, secs)
end

-- ── 工具 ─────────────────────────────────────────────────────────────

local function is_local(p)
    if not p or p == '' then return false end
    if p:match('^%a:[/\\]') then return true end
    local c1 = p:sub(1, 1)
    return c1 == '\\' or c1 == '/'
end

local function basename(p)
    return p and p:match('[^/\\]+$') or '?'
end

-- ── URL / 来源解析 ───────────────────────────────────────────────────

local function url_host(p)      -- 取 host（含端口），非 URL 返回 nil
    return p and p:match('^%a[%w+.-]*://([^/?#]+)') or nil
end

local function is_loopback_host(h)   -- 本机回环（本地中继/代理）
    if not h then return false end
    local host = h:lower():gsub(':%d+$', '')
    return host == 'localhost' or host == '127.0.0.1' or host == '::1' or host == '[::1]'
end

-- ⭐飞牛影视(FnTV)的本地中继地址：http://127.0.0.1:22345/api/v1/playvideo/<itemGuid>?session=<token>
--   三个坑：① host 是回环，不是 NAS 真地址（真地址形如 <NAS-IP>:<端口>）；
--   ② session 每播一次就换 ⇒ 同一集会被当成新条目重复入史；
--   ③ 只有飞牛影视进程活着、且该播放会话没过期时才播得动（关掉飞牛影视必失败）。
--   itemGuid 才是稳定标识，用它做身份归一。
local function fnt_item_guid(p)      -- 命中飞牛中继则返回 itemGuid
    if not p then return nil end
    local h, path = p:match('^https?://([^/]+)(/.*)$')
    if not h or not path or not is_loopback_host(h) then return nil end
    return path:match('^/api/v1/playvideo/([^/?#]+)')
end

local FNT_KEY = 'fntv'
local FNT_LABEL = SOURCE_NAMES[FNT_KEY] or '飞牛影视'

-- 身份键：飞牛中继按 itemGuid 归一（同一集不同 session 视为同一条），其余按原路径
local function identity(p)
    local guid = fnt_item_guid(p)
    if guid then return FNT_KEY .. ':' .. guid end
    return p
end

-- URL 末段（去查询串/锚点，做一次 %xx 解码）—— 退化标题用
local function title_from_url(p)
    if not p or not p:find('://') then return nil end
    local noq = p:gsub('[?#].*$', '')
    local seg = noq:match('([^/]+)/*$')
    if not seg or seg == '' then return nil end
    seg = seg:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
    if #seg > 80 then seg = seg:sub(1, 77) .. '...' end
    return seg
end

-- 疑似 URL / 高熵 token（「一串代码」）——只用于网络条目
local function looks_like_token(s)
    if not s or s == '' then return false end
    if s:find('://') then return true end
    if #s < 24 or s:find(' ') then return false end
    if s:find('%.%a%a%a?%a?$') then return false end       -- 带扩展名，像文件名，不算
    return (s:match('%a') ~= nil) and (s:match('%d') ~= nil)
end

-- 飞牛影视的 force-media-title 会带它自己的占位词（集标题为空填 noTitle、
-- 剧名为空填 noTVTitle）：如「剧名 - S1E5: noTitle」应显示为「剧名 - S1E5」。
local function strip_fnt_placeholder(t)
    if not t or t == '' then return t end
    t = t:gsub('%s*[:：]%s*noTitle%s*$', '')
    t = t:gsub('^%s*noTVTitle%s*[-–—]%s*', '')
    t = t:gsub('^%s*noTitle%s*$', '')
    t = t:gsub('^%s*noTVTitle%s*$', '')
    return (t:gsub('%s+$', ''))
end

-- 标题里还留着飞牛占位词 ⇒ 视为「没信息量」，可被更好的标题替换
local function has_fnt_placeholder(t)
    if not t or t == '' then return false end
    if t:find('noTitle', 1, true) then return true end
    if t:find('noTVTitle', 1, true) then return true end
    return false
end

-- 可读标题：本地取文件名；网络流若标题是乱码则退化成 URL 末段 / 域名。
-- 飞牛中继单独处理：mpv 侧常只拿得到一串 itemGuid（32 位十六进制），
-- 宁可显示「飞牛影视 · 4c96a3f4」，也不要把那串 id 原样糊在界面上。
local function clean_title(raw_title, p)
    local guid = fnt_item_guid(p)
    if guid then
        if raw_title and raw_title ~= '' and raw_title ~= guid
            and not looks_like_token(raw_title) then
            local t = strip_fnt_placeholder(raw_title)
            if t ~= nil and t ~= '' then return t end
        end
        return FNT_LABEL .. ' · ' .. guid:sub(1, 8)
    end
    if is_local(p) then
        return (raw_title and raw_title ~= '' and raw_title) or basename(p)
    end
    if raw_title and raw_title ~= '' and not looks_like_token(raw_title) then return raw_title end
    local from_url = title_from_url(p)
    if from_url and #from_url >= 3 then return from_url end
    if raw_title and raw_title ~= '' then return raw_title end
    local h = url_host(p)
    return (h and ('网络流 · ' .. h)) or '网络流'
end

-- 弱标题 = 没有信息量（空 / 一串 token / 由 itemGuid 拼出来的占位名）
local function weak_title(t, p)
    if not t or t == '' then return true end
    if looks_like_token(t) then return true end
    if has_fnt_placeholder(t) then return true end   -- 「: noTitle」这类占位名允许被升级
    local guid = fnt_item_guid(p)
    return guid ~= nil and t == FNT_LABEL .. ' · ' .. guid:sub(1, 8)
end

-- ⭐只升级不降级：拿到可读标题后，后到的 token 型标题不许把它冲掉。
-- 这正是「退出 mpv 后标题变成一串数字」的成因：退出瞬间 media-title 已经空了，
-- 标题被 URL 末段（= itemGuid）覆盖。
local function better_title(old, new, p)
    if not new or new == '' then return false end
    if not old or old == '' then return true end
    if old == new then return false end
    if not weak_title(old, p) then return false end   -- 已有可读标题 ⇒ 不降级
    return true
end

-- 来源键：网络条目按 host 分组（如 net:192.168.1.9）
local function stream_key(p)
    local h = url_host(p)
    if not h or h == '' then return '__stream__' end
    return 'net:' .. h:lower()
end

-- 需要「调用方程序活着」才能播的地址（本地中继，如飞牛影视的
-- http://127.0.0.1:22345/api/v1/playvideo/<itemGuid>?session=<token>）。
-- ⭐它和「死链」是两件事：调用方进程在跑、会话没过期就真能播 ⇒ 不能当废链判死，
--   只单独标注「需飞牛影视运行」，点播时交给 watch_stream 的 6 秒兜底去验证。
local function needs_caller(p)
    return fnt_item_guid(p) ~= nil
end

-- 带「过期/签名」类参数的链接通常是临时地址，随时会失效
local EXPIRING_PARAMS = {'expire', 'expires', 'expiry', 'deadline', 'valid_until',
                         'sign', 'signature', 'sig', 'hmac', 'st', 'et'}
local function looks_ephemeral(p)
    if needs_caller(p) then
        return false  -- 本机中继不算废链：调用方在跑就可播（另由 needs_caller 标注）
    end
    if is_loopback_host(url_host(p)) then
        return true   -- 其他指向本机代理的地址：进程一关就没人应答
    end
    local q = (p and p:match('%?([^#]*)') or ''):lower()
    if q == '' then return false end
    q = '&' .. q            -- 统一成 &k=v 形式，用纯文本查找（Lua 模式无 | 交替）
    for _, k in ipairs(EXPIRING_PARAMS) do
        if q:find('&' .. k .. '=', 1, true) then return true end
    end
    return false
end

-- 网络记录是否可点播
local function stream_playable(p)
    if is_local(p) then return true end
    local mode = tostring(o.stream_play or 'auto')
    if mode == 'always' then return true end
    if mode == 'never' then return false end
    return not looks_ephemeral(p)
end

-- 「可放心直接续播」：既能点播，又不需要外部程序在场
-- （飞牛中继不算：它要调用方进程在场，空格续播不该指向它）
local function directly_playable(p)
    return stream_playable(p) and not needs_caller(p)
end

-- 常见播放后端指纹（用于自动给来源命名）
local function app_fingerprint(p)
    local pl = (p or ''):lower()
    if pl:find('x%-plex%-token') or pl:find('/library/metadata/') or pl:find('/video/:/') then return 'Plex' end
    if pl:find('/emby/') then return 'Emby' end
    if pl:find('jellyfin') or (pl:find('/videos/') and (pl:find('api_key') or pl:find('apikey'))) then return 'Jellyfin' end
    return nil
end

local function fmt_time(sec)
    if not sec or sec < 0 then return '?' end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = math.floor(sec % 60)
    if h > 0 then
        return string.format('%d:%02d:%02d', h, m, s)
    end
    return string.format('%02d:%02d', m, s)
end

local function fmt_ago(ts)
    local d = os.time() - (ts or os.time())
    if d < 60 then return '刚刚'
    elseif d < 3600 then return math.floor(d / 60) .. '分钟前'
    elseif d < 86400 then return math.floor(d / 3600) .. '小时前'
    elseif d < 86400 * 30 then return math.floor(d / 86400) .. '天前'
    end
    return os.date('%Y-%m-%d', ts)
end

-- 有效条目 = 真播过（进度 >= 1 秒）。仅被加载未播放的条目（pos 恒为 0）视为垃圾。
local MIN_VALID_POS = 1
local function is_valid(e)
    return type(e) == 'table' and e.path ~= nil and (e.pos or 0) >= MIN_VALID_POS
end

-- ── 状态读写 ─────────────────────────────────────────────────────────

-- 同身份合并：把 dup 并进 keep（进度取更靠后的那条，标题取更可读的那个）
local function merge_dup(keep, dup)
    if (dup.pos or 0) > (keep.pos or 0) then keep.pos = dup.pos end
    if better_title(keep.title, dup.title, dup.path) then keep.title = dup.title end
    if (dup.ts or 0) > (keep.ts or 0) then
        keep.ts = dup.ts
        keep.path = dup.path       -- 更近的那次播放，地址（会话）更可能还活着
    end
    if (not keep.dur or keep.dur <= 0) and (dup.dur or 0) > 0 then keep.dur = dup.dur end
    if (dup.ord or 0) > (keep.ord or 0) then keep.ord = dup.ord end
    if not keep.dir then keep.dir = dup.dir end
    return keep
end

local function load_state()
    local f = io.open(HISTORY_FILE, 'r')
    if not f then return {} end
    local s = f:read('*a')
    f:close()
    local ok, data = pcall(utils.parse_json, s or '')
    if ok and type(data) == 'table' and type(data.entries) == 'table' then
        local list = {}
        -- ord = 排序键（默认取 ts，允许菜单里的 ↑↓ 手动调序）
        -- 只收真播过的：被播放列表短暂加载、从未播放的条目直接丢弃
        for _, e in ipairs(data.entries) do
            if is_valid(e) then
                e.ord = e.ord or e.ts or 0
                if e.title then e.title = strip_fnt_placeholder(e.title) end  -- 老记录里的「: noTitle」自愈
                list[#list + 1] = e
            end
        end
        table.sort(list, function(a, b) return (a.ord or 0) > (b.ord or 0) end)
        -- 读盘即去重：旧版本留下的「同一集不同 session 两条」在这里合掉
        local seen, out = {}, {}
        for _, e in ipairs(list) do
            local key = identity(e.path)
            if seen[key] then
                merge_dup(seen[key], e)
            else
                seen[key] = e
                out[#out + 1] = e
            end
        end
        out = out
        table.sort(out, function(a, b) return (a.ord or 0) > (b.ord or 0) end)
        return out
    end
    msg.warn('history file unreadable, starting fresh')
    return {}
end

local function next_ord()  -- 手动排序用：永远取最大 ord + 1（置顶）
    local max = 0
    for _, e in ipairs(entries or {}) do
        if (e.ord or 0) > max then max = e.ord end
    end
    return max + 1
end

-- 读盘（供合并用）
local function read_disk_entries()
    local f = io.open(HISTORY_FILE, 'r')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    local ok, data = pcall(utils.parse_json, s or '')
    if ok and type(data) == 'table' and type(data.entries) == 'table' then return data.entries end
    return nil
end

-- ⭐合并保护：可能同时有多个 mpv 实例（手动 + FnTV 托管）共用这一个历史文件，
-- 各自定期把内存写盘会互相覆盖。写盘前先并入磁盘上别人新写的条目（按 ts 取新），
-- 本次会话删掉的路径用 tombstone 顶住，避免被别的实例「复活」。
local function merge_disk()
    local disk = read_disk_entries()
    if not disk then return end
    local index = {}
    for _, e in ipairs(entries) do
        if type(e) == 'table' and e.path then index[identity(e.path)] = e end
    end
    for _, de in ipairs(disk) do
        if is_valid(de) then
            local key = identity(de.path)
            if not deleted_paths[key] then
                local mine = index[key]
                if not mine then
                    entries[#entries + 1] = de
                    index[key] = de
                elseif (de.ts or 0) > (mine.ts or 0) then
                    mine.pos = de.pos or mine.pos
                    mine.ts = de.ts
                    mine.ord = de.ord or mine.ord
                    mine.dur = de.dur or mine.dur
                    mine.dir = de.dir or mine.dir
                    if better_title(mine.title, de.title, de.path) then mine.title = de.title end
                end
            end
        end
    end
    table.sort(entries, function(a, b) return (a.ord or 0) > (b.ord or 0) end)
    while #entries > (tonumber(o.max_items) or 500) do
        table.remove(entries)
    end
end

local function save_state()
    if entries == nil then return end
    merge_disk()
    local ok, s = pcall(utils.format_json, {entries = entries})
    if not ok or not s then
        msg.warn('format_json failed, skip save')
        return
    end
    local f = io.open(HISTORY_FILE, 'w')
    if not f then return end
    f:write(s)
    f:close()
end

local function update_button()
    mp.commandv('script-message-to', 'uosc', 'set-button', 'history', utils.format_json({
        icon = 'history',
        tooltip = '播放历史',
        command = 'script-binding playback_history/open',
    }))
end

-- 插入/更新条目（本地与网络流都记；dir 仅本地文件有）
--   pos ~= nil  —— 带真实进度（周期/暂停/退出时的回写）：更新进度并置顶
--   pos == nil  —— 只有元数据的场合（file-loaded）：仅补标题/时长，不算「看过」
--   allow_new   —— 是否允许新建条目；新条目还须 pos >= min_play 才收
local function upsert_entry(p, pos, allow_new)
    local now = os.time()
    local dur = mp.get_property_number('duration')
    local title = clean_title(mp.get_property('media-title'), p)
    local dir = is_local(p) and p:match('^(.*)[/\\][^/\\]+$') or nil
    local key = identity(p)

    for _, e in ipairs(entries) do
        if identity(e.path) == key then
            e.path = p                            -- 刷新为最新地址（飞牛中继的会话会换）
            if pos ~= nil then e.pos = pos end
            e.dur = dur or e.dur
            if better_title(e.title, title, p) then e.title = title end
            if dir then e.dir = dir end
            if pos ~= nil then                    -- 只有真进度才置顶
                e.ts = now
                e.ord = next_ord()
                table.sort(entries, function(a, b) return (a.ord or 0) > (b.ord or 0) end)
            end
            save_state()
            update_button()
            return
        end
    end

    if not allow_new then return end
    if not pos or pos < (tonumber(o.min_play) or 3) then return end

    table.insert(entries, 1, {
        path = p,
        title = title,
        pos = pos,
        dur = dur,
        ts = now,
        ord = next_ord(),
        dir = dir,
    })
    if #entries > (tonumber(o.max_items) or 500) then
        table.remove(entries)
    end
    save_state()
    update_button()
end

-- ⭐播放快照：路径/进度/时长/标题成组存在内存里。
-- 必须自己存 —— 实测 mpv 在 `end-file(reason=quit)` 与 `shutdown` 时，
-- `path` 和 `time-pos` 都返回 `nil property unavailable`；那一刻再现场读属性，
-- 退出进度必然丢（FnTV 正常退出走的就是 IPC `quit`）。切集同理：上一条已经读不到了。
local snap = {path = nil, pos = nil, dur = nil, title = nil}

local function snap_reset(p)
    snap.path = p
    snap.pos = nil
    snap.dur = nil
    snap.title = nil
end

-- 把快照落盘（文件被切走 / 播完 / 退出时用；这些时刻实时属性已不可靠）
local function flush_snapshot()
    local p, pos = snap.path, snap.pos
    if not p or p == '' or not pos or pos <= 0 then return end
    local minp = tonumber(o.min_play) or 3
    local key = identity(p)

    for _, e in ipairs(entries) do
        if identity(e.path) == key then
            -- 短到没真播起来（<min_play）就别把已有的长进度冲掉
            if pos >= minp or not e.pos or pos >= e.pos then
                e.pos = pos
                e.ts = os.time()
                e.ord = next_ord()
                table.sort(entries, function(a, b) return (a.ord or 0) > (b.ord or 0) end)
            end
            e.path = p                                    -- 刷新地址（飞牛中继的 session 会换）
            if snap.dur and snap.dur > 0 then e.dur = snap.dur end
            if snap.title and better_title(e.title, snap.title, p) then e.title = snap.title end
            if is_local(p) then e.dir = p:match('^(.*)[/\\][^/\\]+$') or e.dir end
            save_state()
            update_button()
            return
        end
    end

    if pos < minp then return end
    table.insert(entries, 1, {
        path = p,
        title = snap.title or clean_title(nil, p),
        pos = pos,
        dur = snap.dur,
        ts = os.time(),
        ord = next_ord(),
        dir = is_local(p) and p:match('^(.*)[/\\][^/\\]+$') or nil,
    })
    if #entries > (tonumber(o.max_items) or 500) then table.remove(entries) end
    save_state()
    update_button()
end

-- 刷新快照里的实时字段（只在属性还读得到时有用）；再落盘
local function snap_refresh()
    local p = mp.get_property('path')
    if not p or p == '' then return end
    if snap.path ~= p then snap_reset(p) end
    local pos = mp.get_property_number('time-pos')
    if pos and pos > 0 then snap.pos = pos end
    local d = mp.get_property_number('duration')
    if d and d > 0 then snap.dur = d end
    snap.title = clean_title(mp.get_property('media-title'), p)
end

-- 把当前进度写回置顶条目（网络流也记，用于「看过什么」回溯）
local function save_progress()
    snap_refresh()          -- 退出时这句读不到东西，靠快照兜底
    flush_snapshot()
end

-- ── 续播 ─────────────────────────────────────────────────────────────

local function resume_path(p)
    local e
    for _, it in ipairs(entries) do
        if it.path == p then e = it break end
    end
    if not e then
        osd('记录已不存在', 2)
        return
    end
    pending_resume = {path = e.path, pos = e.pos}
    -- ⭐绝不吞掉 mpv 自己的播放列表：默认的 loadfile 会把整个列表换成这一个文件，
    -- 「打开一整季 / 一个文件夹后自动往下播」就此失效。列表非空时插到当前条目之后播，
    -- 原有条目（含下一集）原样保留，这条播完自动接着原列表继续。
    if (mp.get_property_number('playlist-count') or 0) > 0 then
        mp.commandv('loadfile', e.path, 'insert-next-play')
    elseif (o.list_expand or 'filter') ~= 'no' and is_local(e.path) then
        -- ⭐列表为空时让 mpv 按文件名相似度带出同目录的其余剧集（复刻「打开文件夹」的列表续播）：
        -- per-file option 只对这一次加载生效，不改全局配置；网络流没有目录，不受影响。
        mp.commandv('loadfile', e.path, 'replace', '-1', 'autocreate-playlist=' .. o.list_expand)
    else
        mp.commandv('loadfile', e.path)
    end
end

mp.register_event('file-loaded', function()
    local p = mp.get_property('path')
    if not p or p == '' then return end

    upsert_entry(p, nil, false)  -- 只刷新标题/时长；「看过」以真进度为准
    snap_reset(p)                                       -- 起一段新的快照
    snap.dur = mp.get_property_number('duration')
    snap.title = clean_title(mp.get_property('media-title'), p)
    -- 短片段也给个机会入史：min_play 秒后补一次进度检查（长播靠周期定时器）
    mp.add_timeout((tonumber(o.min_play) or 3) + 1, save_progress)

    -- 续播：仅当本次加载就是「点历史点出来的那个文件」
    local st = pending_resume
    pending_resume = nil
    if not st or st.path ~= p then return end
    local pos = st.pos
    if not pos or pos < (tonumber(o.min_resume) or 30) then return end

    local dur = mp.get_property_number('duration')
    if dur and pos > dur - 15 then return end          -- 快播完了，不续
    local cur = mp.get_property_number('time-pos') or 0
    if cur > 5 then return end                          -- watch_later 已恢复过

    msg.info(string.format('resume from history: %d / %s', pos, dur and math.floor(dur) or '?'))
    mp.commandv('seek', pos, 'absolute')
end)

-- ⭐网络流加载失败兜底：失效地址（或调用方已退出）会让 mpv 空转/报错。
-- 点开后 N 秒内若还没真放起来（回到 idle 或没有 time-pos）→ 判定失效，停止并提示，
-- 绝不让一长串 URL 晾在界面上；收到 end-file(error) 也立刻判失败。
local stream_watch = false
local stream_watch_path = nil

local function stream_fail_msg(p)
    if needs_caller(p) then
        return FNT_LABEL .. '没有运行，或该播放会话已过期；请在' .. FNT_LABEL .. '里打开这一集'
    end
    return '该流地址可能已失效，已取消播放'
end

local function watch_stream(p)
    stream_watch = true
    stream_watch_path = p or mp.get_property('path') or ''
    mp.add_timeout(6, function()
        if not stream_watch then return end
        stream_watch = false
        if mp.get_property_native('idle-active') or mp.get_property_number('time-pos') == nil then
            local cp = mp.get_property('path')
            if not cp or cp == '' then cp = stream_watch_path end
            mp.commandv('stop', 'keep-playlist')   -- ⭐stop 默认会清空整个列表，必须加 keep-playlist
            osd(stream_fail_msg(cp), 4)
        end
    end)
end
mp.register_event('end-file', function(ev)
    if not stream_watch then return end
    if ev and (ev.reason == 'error' or ev.error) then
        stream_watch = false
        local cp = mp.get_property('path')
        if not cp or cp == '' then cp = stream_watch_path end
        mp.add_timeout(0.2, function()
            if mp.get_property_native('idle-active') then osd(stream_fail_msg(cp), 4) end
        end)
    end
end)

-- ── 设置（菜单里可直接改，改完写回 script-opts/playback_history.conf） ──
-- uosc 菜单没有文本输入，数值项做成「点击循环预设值」：够用且不会打错。

local SETTINGS_KEY = '__settings__'
local CONF_FILE = mp.command_native({'expand-path', '~~/script-opts/playback_history.conf'})

local SETTINGS = {
    {key = 'save_interval', label = '进度写盘间隔', choices = {
        {v = 10, t = '10 秒'}, {v = 30, t = '30 秒'}, {v = 60, t = '1 分钟'},
        {v = 300, t = '5 分钟'}, {v = 600, t = '10 分钟'}, {v = 1800, t = '30 分钟'},
    }},
    {key = 'min_play', label = '入历史最小播放', choices = {
        {v = 1, t = '1 秒'}, {v = 3, t = '3 秒'}, {v = 5, t = '5 秒'},
        {v = 10, t = '10 秒'}, {v = 30, t = '30 秒'},
    }},
    {key = 'min_resume', label = '自动续播最小进度', choices = {
        {v = 0, t = '不限制'}, {v = 15, t = '15 秒'}, {v = 30, t = '30 秒'},
        {v = 60, t = '1 分钟'}, {v = 120, t = '2 分钟'},
    }},
    {key = 'max_items', label = '历史条数上限', choices = {
        {v = 30, t = '30 条'}, {v = 50, t = '50 条'}, {v = 100, t = '100 条'},
        {v = 200, t = '200 条'}, {v = 500, t = '500 条'},
    }},
    {key = 'idle_prefer_local', label = '空格续播优先本地', bool = true},
    {key = 'stream_play', label = '网络记录可点播', choices = {
        {v = 'auto', t = '自动判断'}, {v = 'always', t = '全可点'}, {v = 'never', t = '全置灰'},
    }},
}

local DEFAULTS = {save_interval = 1800, min_play = 3, min_resume = 30,
                  max_items = 500, idle_prefer_local = true, stream_play = 'auto'}

-- 写回配置文件：保留原有注释与行序，只替换 key= 那一行（没有则追加）
local function write_option(key, val)
    local lines = {}
    local f = io.open(CONF_FILE, 'r')
    if f then
        for line in f:lines() do lines[#lines + 1] = line end
        f:close()
    end
    local found = false
    for i, line in ipairs(lines) do
        if line:match('^%s*' .. key .. '%s*=') then
            lines[i] = key .. '=' .. tostring(val) .. (line:match('%s+#.*$') or '')
            found = true
            break
        end
    end
    if not found then lines[#lines + 1] = key .. '=' .. tostring(val) end

    local out = io.open(CONF_FILE, 'w')
    if not out then
        msg.warn('cannot write ' .. CONF_FILE)
        osd('配置写入失败（本次会话内仍生效）', 3)
        return
    end
    out:write(table.concat(lines, '\n') .. '\n')
    out:close()
end

local function setting_text(st)
    if st.bool then return o[st.key] and '开' or '关' end
    for _, c in ipairs(st.choices) do
        if tostring(c.v) == tostring(o[st.key]) then return c.t end
    end
    return tostring(o[st.key])
end

-- ⛔ 有行内按钮的行不能再用 hint：uosc 把 hint 的裁剪区右边界卡在按钮左边，
-- 而 hint 是右对齐画到内容区最右边 ⇒ 尾部必被切掉（实测「100 条」只露「10」）。
-- 值并入标题（标题裁剪区只到按钮左边，放得下完整值）；也不给 icon，
-- 否则未选中行会在最右端多露一个图标。
local function setting_row(st)
    return {
        title = st.label .. ' · ' .. setting_text(st),
        value = {setting = st.key},
        actions = {
            {name = 'dec', icon = 'chevron_left', label = '上一档'},
            {name = 'inc', icon = 'chevron_right', label = '下一档'},
        },
        actions_place = 'inside',
    }
end

-- 主/子文件夹视图共用的工具行：左边「清空」（按当前作用域），右边「设置」；点行本身=进设置
local function tools_row(clear_label)
    return {
        title = '设置',
        value = '__settings__',
        actions = {
            {name = 'clear_scope', icon = 'delete', label = clear_label},
            {name = 'settings', icon = 'settings', label = '设置'},
        },
        actions_place = 'inside',
    }
end

local function apply_setting(key, dir)
    for _, st in ipairs(SETTINGS) do
        if st.key == key then
            if st.bool then
                -- dir=nil（整行点击）→ 取反；dir>0 → 开；dir<0 → 关
                o[st.key] = dir == nil and (not o[st.key]) or (dir > 0)
            else
                local n = #st.choices
                local idx = 0
                for i, c in ipairs(st.choices) do
                    if tostring(c.v) == tostring(o[st.key]) then idx = i end
                end
                local step = dir or 1
                if idx == 0 then
                    o[st.key] = step > 0 and st.choices[1].v or st.choices[n].v
                else
                    o[st.key] = st.choices[(idx - 1 + step) % n + 1].v
                end
            end
            if key == 'save_interval' and save_timer then
                save_timer.timeout = tonumber(o[key]) or 10
            end
            write_option(key, st.bool and (o[key] and 'yes' or 'no') or o[key])
            osd(st.label .. '：' .. setting_text(st), 2)
            return
        end
    end
end

local function reset_settings()
    for k, v in pairs(DEFAULTS) do
        o[k] = v
        write_option(k, type(v) == 'boolean' and (v and 'yes' or 'no') or v)
    end
    if save_timer then save_timer.timeout = tonumber(o.save_interval) or 1800 end
    osd('已恢复默认设置', 2)
end

-- ── 菜单：按文件夹分层的「播放历史」（callback 模式，点击以 JSON 事件回传） ──
-- 根视图（播放历史）= 本地父文件夹（如「无职转生3\」）+ 网络来源（如「FnTV\」「Plex\」）；
-- 目录视图（如「无职转生3\」）= 首项「..（父文件夹）」返回 + 该目录下的记录，
-- 每条记录行尾内嵌删除按钮（actions_place='inside'，与播放列表一致）。

local OTHER_KEY = '__other__'  -- 本地但取不到父目录时的兜底分组

local current_dir = nil        -- nil=根视图；否则为分组 key

local function entry_dir(e)  -- 老记录没有 dir 字段，按路径推导
    if e.dir and e.dir ~= '' then return e.dir end
    if is_local(e.path) then return e.path:match('^(.*)[/\\][^/\\]+$') end
end

local function group_key(e)
    if fnt_item_guid(e.path) then return FNT_KEY end              -- 飞牛中继 → 「飞牛影视」
    if not is_local(e.path) then return stream_key(e.path) end    -- 其它网络条目按来源(host)分组
    return entry_dir(e) or OTHER_KEY
end

-- 分组显示名：本地=文件夹名；网络=别名 → 软件指纹 → 域名
local function group_label(key)
    if key == FNT_KEY then return FNT_LABEL .. '\\' end
    if key == OTHER_KEY then return '其他\\' end
    if key == '__stream__' then return '网络流\\' end
    if key:sub(1, 4) == 'net:' then
        local host = key:sub(5)
        -- 别名匹配：先按「host:端口」，再按去掉端口的 host（配置里写 192.168.1.9 也能命中 :5244）
        local name = SOURCE_NAMES[host] or SOURCE_NAMES[host:gsub(':.*$', '')]
        if not name then
            for _, e in ipairs(entries or {}) do
                if not is_local(e.path) and stream_key(e.path) == key then
                    name = app_fingerprint(e.path)
                    if name then break end
                end
            end
        end
        if not name then name = host:gsub(':.*$', '') end
        return name .. '\\'
    end
    local name = key:match('[^/\\]+$')
    return (name and name ~= '' and name or key) .. '\\'
end

local function sorted_entries()  -- 按 ord（可手动调序）排序，最近在前
    local list = {}
    for _, e in ipairs(entries or {}) do list[#list + 1] = e end
    table.sort(list, function(a, b) return (a.ord or 0) > (b.ord or 0) end)
    return list
end

local function entry_item(e, with_move)
    local label = clean_title(e.title, e.path)
    local hint = fmt_time(e.pos)
    if e.dur and e.dur > 0 then hint = hint .. ' / ' .. fmt_time(e.dur) end
    hint = hint .. ' · ' .. fmt_ago(e.ts)
    -- ⚠顺序：先判「彻底不可播」（真废链 / stream_play=never），再判「只缺调用方在场」
    if not stream_playable(e.path) then hint = hint .. ' · 仅记录'
    elseif needs_caller(e.path) then hint = hint .. ' · 需' .. FNT_LABEL .. '运行' end
    local actions = {}
    if with_move then
        actions[#actions + 1] = {name = 'move_up', icon = 'arrow_upward', label = '上移'}
        actions[#actions + 1] = {name = 'move_down', icon = 'arrow_downward', label = '下移'}
    end
    actions[#actions + 1] = {name = 'delete', icon = 'delete', label = '删除此记录'}
    return {
        title = label,
        hint = hint,
        value = e.path,
        muted = not stream_playable(e.path),  -- 不可续播的网络记录置灰
        actions = actions,
        actions_place = 'inside',
    }
end

local function open_menu(opts)
    opts = opts or {}
    -- 默认视图 = 最近一条记录所在的文件夹（退到根后不再自动跳）
    if opts.default_dir and current_dir == nil and entries and #entries > 0 then
        local first = sorted_entries()[1]
        if first then current_dir = group_key(first) end
    end

    local items = {}
    local title = '播放历史'
    local footnote = '点击播放 · 悬停行尾按钮'

    if current_dir == SETTINGS_KEY then
        title = '播放历史 · 设置'
        footnote = '点行内 ◀ ▶ 换档 · 立即写入配置文件'
        items[1] = {title = '..', hint = '返回', value = '__back__', separator = true}
        for _, st in ipairs(SETTINGS) do items[#items + 1] = setting_row(st) end
        items[#items + 1] = {
            title = '恢复默认设置',
            value = '',
            actions = {{name = 'reset_defaults', icon = 'restart_alt', label = '恢复默认设置'}},
            actions_place = 'inside',
        }
    elseif not entries or #entries == 0 then
        items[1] = {title = '暂无播放记录', muted = true, selectable = false, value = ''}
        items[2] = tools_row('清空播放历史')
    elseif current_dir == nil then
        -- 根视图：按父文件夹分组，组间按组内最新记录排序
        local groups, order = {}, {}
        for _, e in ipairs(sorted_entries()) do
            local key = group_key(e)
            if not groups[key] then
                groups[key] = {n = 0, latest = e.ord or 0}
                order[#order + 1] = key
            end
            groups[key].n = groups[key].n + 1
        end
        table.sort(order, function(a, b) return groups[a].latest > groups[b].latest end)
        for i, key in ipairs(order) do
            items[i] = {
                title = group_label(key),
                hint = groups[key].n .. ' 条',
                icon = 'folder',
                value = {dir = key},
            }
        end
        items[#items + 1] = tools_row('清空播放历史')
    else
        -- 目录视图
        title = group_label(current_dir)
        footnote = '点击播放 · 悬停行尾：上移 / 下移 / 删除'
        items[1] = {title = '..', hint = '父文件夹', value = '__back__', separator = true}
        for _, e in ipairs(sorted_entries()) do
            if group_key(e) == current_dir then items[#items + 1] = entry_item(e, true) end
        end
        if #items == 1 then
            items[#items + 1] = {title = '（空）', muted = true, selectable = false, value = ''}
        end
        items[#items + 1] = tools_row('清空本文件夹记录')
    end

    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json({
        type = 'playback_history',
        title = title,
        footnote = footnote,
        callback = {'playback_history', 'menu-event'},
        items = items,
    }))
end

mp.add_key_binding(nil, 'open', function() open_menu({default_dir = true}) end)
mp.register_script_message('save', save_state)  -- 手动存盘（调试/外部脚本用）

local function close_menu()
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'playback_history')
end

local function move_entry(p, delta)  -- delta: -1 上移 / +1 下移（当前视图内）
    local list = {}
    for _, e in ipairs(sorted_entries()) do
        if current_dir == nil or group_key(e) == current_dir then list[#list + 1] = e end
    end
    local idx
    for i, e in ipairs(list) do
        if e.path == p then idx = i break end
    end
    if not idx then return end
    local other = list[idx + delta]
    if not other then return end
    list[idx].ord, other.ord = other.ord, list[idx].ord
    table.sort(entries, function(a, b) return (a.ord or 0) > (b.ord or 0) end)
    save_state()
    open_menu()
end

local function delete_entry(p)
    for i, e in ipairs(entries) do
        if e.path == p then
            local was_key = group_key(e)
            deleted_paths[identity(e.path)] = true
            table.remove(entries, i)
            -- 目录视图里删空了就退回根视图
            if current_dir ~= nil then
                local left = false
                for _, it in ipairs(entries) do
                    if group_key(it) == was_key then left = true break end
                end
                if not left then current_dir = nil end
            end
            save_state()
            update_button()
            osd('已从播放历史删除', 2)
            open_menu()  -- 刷新菜单
            return
        end
    end
end

local function clear_current_dir()
    local key = current_dir
    local kept = {}
    for _, e in ipairs(entries) do
        if group_key(e) == key then
            deleted_paths[identity(e.path)] = true
        else
            kept[#kept + 1] = e
        end
    end
    entries = kept
    current_dir = nil
    save_state()
    update_button()
    osd('已清空该文件夹的记录', 2)
    open_menu()
end

local function clear_all()
    for _, e in ipairs(entries or {}) do deleted_paths[identity(e.path)] = true end
    entries = {}
    current_dir = nil
    save_state()
    update_button()
    osd('播放历史已清空', 2)
    open_menu()
end

mp.register_script_message('menu-event', function(json)
    local ok, event = pcall(utils.parse_json, json or '')
    if not ok or type(event) ~= 'table' or event.type ~= 'activate' then return end
    local v, act = event.value, event.action

    -- 行内按钮先于整行点击处理：「清空本文件夹」按钮挂在「..」行上，其 value 是 __back__
    if act == 'inc' or act == 'dec' then
        if type(v) == 'table' and v.setting then
            apply_setting(v.setting, act == 'inc' and 1 or -1)
            open_menu()
        end
        return
    elseif act == 'reset_defaults' then reset_settings() open_menu() return
    elseif act == 'clear_all' then clear_all() return
    elseif act == 'clear_scope' then
        if current_dir == nil then clear_all() else clear_current_dir() end
        return
    elseif act == 'settings' then current_dir = SETTINGS_KEY open_menu() return
    elseif act == 'delete' then delete_entry(v) return
    elseif act == 'move_up' then move_entry(v, -1) return
    elseif act == 'move_down' then move_entry(v, 1) return
    end

    if type(v) == 'table' then            -- 文件夹项进目录视图；设置项整行点击=下一档
        if v.dir then
            current_dir = v.dir
            open_menu()
        elseif v.setting then
            apply_setting(v.setting, 1)
            open_menu()
        end
        return
    end

    if v == '__settings__' then
        current_dir = SETTINGS_KEY
        open_menu()
    elseif v == '__back__' then
        current_dir = nil
        open_menu()
    elseif type(v) == 'string' and v ~= '' then
        -- 飞牛中继：调用方在跑就真能播（川实测），别一刀切拒绝；
        -- 失败由 watch_stream 的 6 秒兜底报错（文案区分「没运行/会话过期」与「链接失效」）
        if not stream_playable(v) then
            osd('该记录地址疑似已失效，仅作查看（可在设置里改为允许点播）', 3)
        else
            resume_path(v)
            if not is_local(v) then watch_stream(v) end   -- 网络流加载失败兜底
            close_menu()  -- 成功播放后自动关闭历史窗口
        end
    end
end)

-- ── 空待命：空格 / 回车 / 左键 = 续播最近一条 ─────────────────────────

-- 空启动续播挑哪一条：默认最近一条；若最近一条不可直接播（网络流/飞牛中继）且
-- idle_prefer_local 开着，则改用最近一条「可直接播」的记录。
-- ⚠判据必须用 directly_playable，不能用 stream_playable：后者对飞牛中继也返回 true
--   （auto/always 都一样），会把空格续播引向一条需要飞牛在跑的地址（实测踩过）。
-- 返回 entry, skipped_remote
local function pick_idle_entry()
    if not entries or #entries == 0 then return nil, false end
    local top = entries[1]
    if o.idle_prefer_local and not directly_playable(top.path) then
        for _, e in ipairs(entries) do
            if directly_playable(e.path) then return e, true end
        end
    end
    return top, false
end

local function idle_resume_latest()
    local e = pick_idle_entry()
    if not e then
        osd('没有播放记录', 2)
        return
    end
    -- 开了「优先本地」却仍拿到不可续播的记录 = 没有别的可续 ⇒ 不去拉可能已失效的地址
    if not directly_playable(e.path) and o.idle_prefer_local then
        osd('最近的记录不可直接续播，且无其他可续记录（可打开播放历史查看）', 3)
        return
    end
    resume_path(e.path)
    if not is_local(e.path) then watch_stream(e.path) end
end

local function idle_bindings_bind()
    mp.add_forced_key_binding('SPACE', 'ph/space', idle_resume_latest)
    mp.add_forced_key_binding('ENTER', 'ph/enter', idle_resume_latest)
    mp.add_forced_key_binding('MBTN_LEFT', 'ph/lmb', idle_resume_latest)
end

local function idle_bindings_unbind()
    mp.remove_key_binding('ph/space')
    mp.remove_key_binding('ph/enter')
    mp.remove_key_binding('ph/lmb')
end

-- ⭐idle-active 只表示「没在播」，**不等于没有播放列表**：停止播放但列表还在时它同样是 true。
-- 那种状态下空格 / 回车 / 左键是 mpv 自带的列表操作（ENTER = 下一集），被我们接管就是破坏
-- mpv 自己的列表功能。只有「既没在播、列表也空」才接管按键。
local function refresh_idle_state()
    local idle = mp.get_property_native('idle-active')
    local has_list = (mp.get_property_number('playlist-count') or 0) > 0
    if not (idle and not has_list) then
        idle_bindings_unbind()
        return
    end
    idle_bindings_bind()
    local ipc = mp.get_property('options/input-ipc-server')
    if ipc and ipc ~= '' then return end
    local e, skipped = pick_idle_entry()
    local hint
    if not e then
        hint = '空格 / 点击播放（当前无播放记录）'
    elseif not directly_playable(e.path) then
        hint = '最近的记录不可直接续播（可打开播放历史查看）'
    else
        hint = '空格 / 点击续播' .. (skipped and '（已跳过不可续播的）' or '')
            .. '：' .. ((e.title and e.title ~= '' and e.title) or basename(e.path))
    end
    -- 刚给过明确提示（如「地址已失效」）时不抢屏：先让人看清为什么没播成
    mp.add_timeout(0.3, function()
        if mp.get_time() >= hint_mute_until then mp.osd_message(hint, 3) end
    end)
end
mp.observe_property('idle-active', 'bool', function() refresh_idle_state() end)
mp.observe_property('playlist-count', 'number', function() refresh_idle_state() end)

-- ── 启动 ─────────────────────────────────────────────────────────────

entries = load_state()

mp.observe_property('pause', 'bool', function(_, paused)
    if paused then save_progress() end
end)

mp.register_event('shutdown', save_progress)
save_timer = mp.add_periodic_timer(tonumber(o.save_interval) or 1800, save_progress)

-- ⭐切集即落盘上一条（FnTV 是一整季 loadlist，切集时上一条的进度读都读不到）
mp.observe_property('path', 'string', function(_, p)
    if snap.path and p ~= snap.path then flush_snapshot() end
    if p and p ~= '' and p ~= snap.path then snap_reset(p) end
end)
-- 结束（含 quit/error）时也落一次，此时实时属性已失效，全靠快照
mp.register_event('end-file', function()
    flush_snapshot()
end)
-- 只刷新快照、不写盘：保证长时间不停不暂停时退出也有最新进度
mp.add_periodic_timer(2, function()
    local p = mp.get_property('path')
    if not p or p == '' then return end
    if snap.path ~= p then snap_reset(p) end
    local pos = mp.get_property_number('time-pos')
    if pos and pos > 0 then snap.pos = pos end
    local d = mp.get_property_number('duration')
    if d and d > 0 then snap.dur = d end
    snap.title = clean_title(mp.get_property('media-title'), p)
end)

update_button()
