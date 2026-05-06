-- luamemo.web
--
-- Web browser for stored memories. Mount with:
--
--     local memory = require("luamemo")
--     memory.web.register(app, { prefix = "/memory/ui" })
--
-- Phases shipped:
--   6.1 — read-only list + detail
--   6.2 — search + scope/kind filters
--   6.3 — inline edit + delete with double-submit-cookie CSRF
--
-- Rendering is pure Lua (no etlua / lustache dependency) so the sub-app
-- has zero coupling to the host app's view layer. CSS is inlined into a
-- single layout function.

local M = {}

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local function get_cfg() return require("luamemo").config end

local function authorise(self)
    local cfg = get_cfg()
    if cfg.before_request then
        local ok, err = cfg.before_request(self)
        if not ok then
            return { status = (err and err.status) or 403,
                     content_type = "text/plain",
                     (err and err.message) or "forbidden" }
        end
    end
    if not cfg.auth_fn(self) then
        return { status = 403, content_type = "text/plain", "forbidden" }
    end
    return nil
end

local HTML_ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
                   ['"'] = "&quot;", ["'"] = "&#39;" }
local function esc(s)
    if s == nil then return "" end
    return (tostring(s):gsub("[&<>\"']", HTML_ESC))
end

local function fmt_age(ts)
    if not ts then return "" end
    -- ts is ISO-ish; just show it verbatim, callers can read the date.
    return esc(tostring(ts))
end

local function effective_weight(row)
    local imp = tonumber(row.importance) or 1.0
    local dr  = tonumber(row.decay_rate) or 0.0
    if dr == 0 then return imp end
    -- Approximate days since updated_at by parsing yyyy-mm-dd prefix; fall
    -- back to importance if the timestamp can't be read.
    local y, m, d = tostring(row.updated_at or ""):match("^(%d+)-(%d+)-(%d+)")
    if not y then return imp end
    local then_t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
    local age_days = math.max(0, (os.time() - then_t) / 86400)
    return imp * math.exp(-dr * age_days)
end

-- ---------------------------------------------------------------------------
-- CSRF: double-submit cookie. Token is opaque random hex; same value lives
-- in `lm_csrf` cookie and a hidden form field. POST handlers compare both.
-- ---------------------------------------------------------------------------
local CSRF_COOKIE = "lm_csrf"

local function rand_hex(bytes)
    local ok_rand, rand = pcall(require, "resty.random")
    local ok_str,  str  = pcall(require, "resty.string")
    if ok_rand and ok_str and rand.bytes then
        return str.to_hex(rand.bytes(bytes))
    end
    -- Fallback: not cryptographic, but this UI is meant for OpenResty.
    math.randomseed(os.time() + (tonumber(tostring({}):match("0x(%x+)"), 16) or 0))
    local out = {}
    for i = 1, bytes * 2 do
        out[i] = string.format("%x", math.random(0, 15))
    end
    return table.concat(out)
end

local function read_cookie(self, name)
    -- Lapis exposes cookies via self.cookies (a table proxy).
    if self.cookies and self.cookies[name] then return self.cookies[name] end
    -- ngx fallback.
    local h = ngx and ngx.var and ngx.var["cookie_" .. name]
    return h
end

local function ensure_csrf(self)
    local tok = read_cookie(self, CSRF_COOKIE)
    if tok and #tok >= 32 then return tok end
    tok = rand_hex(16)
    if self.cookies then self.cookies[CSRF_COOKIE] = tok end
    return tok
end

local function ct_eq(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if #a ~= #b then return false end
    -- Byte-by-byte without short-circuit. Not strictly CT under LuaJIT but
    -- close enough for an admin UI; we OR all diff bytes into one accumulator.
    local diff = 0
    for i = 1, #a do
        if a:byte(i) ~= b:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

local function check_csrf(self)
    local cookie_tok = read_cookie(self, CSRF_COOKIE)
    local form_tok   = self.params and self.params.csrf
    if not cookie_tok or not form_tok or not ct_eq(cookie_tok, form_tok) then
        return { status = 403, content_type = "text/plain", "csrf check failed" }
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- layout + pages
-- ---------------------------------------------------------------------------
local CSS = [[
  body { font: 14px/1.45 system-ui, sans-serif; margin: 0; color: #222; background: #f7f7f8; }
  header { background: #1f2937; color: #fff; padding: 12px 24px; }
  header a { color: #cbd5e1; text-decoration: none; margin-right: 16px; }
  header a:hover { color: #fff; }
  main { max-width: 1100px; margin: 0 auto; padding: 24px; }
  h1 { font-size: 18px; margin: 0 0 16px; }
  table { width: 100%; border-collapse: collapse; background: #fff;
          box-shadow: 0 1px 2px rgba(0,0,0,.05); }
  th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid #e5e7eb;
           vertical-align: top; }
  th { background: #f3f4f6; font-weight: 600; font-size: 12px; text-transform: uppercase;
       letter-spacing: .04em; color: #4b5563; }
  tr:hover td { background: #fafafa; }
  td.body { color: #374151; max-width: 480px; overflow: hidden; text-overflow: ellipsis;
            white-space: nowrap; }
  td.scope { font-family: ui-monospace, monospace; color: #6b7280; }
  td.kind  { font-family: ui-monospace, monospace; color: #2563eb; }
  td.num   { text-align: right; font-variant-numeric: tabular-nums; }
  a.row    { color: #1d4ed8; text-decoration: none; font-weight: 500; }
  a.row:hover { text-decoration: underline; }
  .pager { margin-top: 16px; font-size: 13px; }
  .pager a { color: #1d4ed8; text-decoration: none; padding: 4px 10px; border: 1px solid #d1d5db;
             border-radius: 4px; margin-right: 6px; background: #fff; }
  .pager a.disabled { color: #9ca3af; pointer-events: none; }
  .empty { padding: 32px; text-align: center; color: #6b7280; background: #fff;
           border-radius: 6px; }
  .detail { background: #fff; padding: 20px 24px; border-radius: 6px;
            box-shadow: 0 1px 2px rgba(0,0,0,.05); }
  .detail h2 { margin: 0 0 4px; font-size: 18px; }
  .meta-grid { display: grid; grid-template-columns: 140px 1fr; gap: 4px 16px;
               margin: 16px 0; font-size: 13px; }
  .meta-grid dt { color: #6b7280; }
  .meta-grid dd { margin: 0; font-family: ui-monospace, monospace; color: #111827;
                  word-break: break-all; }
  .body-block { white-space: pre-wrap; font-family: ui-monospace, monospace;
                background: #f9fafb; padding: 16px; border-radius: 4px;
                border: 1px solid #e5e7eb; max-height: 600px; overflow-y: auto; }
  .json-block { font-family: ui-monospace, monospace; font-size: 12px;
                background: #f9fafb; padding: 8px 12px; border-radius: 4px;
                border: 1px solid #e5e7eb; overflow-x: auto; }
  form.filters { display: flex; gap: 8px; margin-bottom: 16px; flex-wrap: wrap;
                 align-items: center; }
  form.filters input[type=text], form.filters select {
      padding: 6px 10px; border: 1px solid #d1d5db; border-radius: 4px;
      font-size: 13px; background: #fff; color: #111827; }
  form.filters input[type=text] { min-width: 280px; }
  form.filters button { padding: 6px 14px; background: #1d4ed8; color: #fff;
      border: 0; border-radius: 4px; font-size: 13px; cursor: pointer; }
  form.filters button:hover { background: #1e40af; }
  form.filters a.clear { font-size: 12px; color: #6b7280; text-decoration: none; }
  form.filters a.clear:hover { color: #1d4ed8; text-decoration: underline; }
  .result-meta { font-size: 12px; color: #6b7280; margin-bottom: 12px; }
  form.edit { margin-top: 24px; padding-top: 16px; border-top: 1px solid #e5e7eb; }
  form.edit label { display: block; font-size: 12px; color: #6b7280;
      text-transform: uppercase; letter-spacing: .04em; margin: 12px 0 4px; }
  form.edit input[type=text], form.edit textarea {
      width: 100%; padding: 8px 10px; border: 1px solid #d1d5db;
      border-radius: 4px; font-size: 13px; font-family: inherit; box-sizing: border-box; }
  form.edit textarea { font-family: ui-monospace, monospace; min-height: 200px; }
  form.edit .row2 { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .actions-row { margin-top: 20px; display: flex; gap: 12px; align-items: center; }
  button.primary { padding: 8px 18px; background: #1d4ed8; color: #fff;
      border: 0; border-radius: 4px; font-size: 13px; cursor: pointer; }
  button.primary:hover { background: #1e40af; }
  button.danger { padding: 8px 18px; background: #dc2626; color: #fff;
      border: 0; border-radius: 4px; font-size: 13px; cursor: pointer; }
  button.danger:hover { background: #b91c1c; }
  .flash { padding: 10px 14px; border-radius: 4px; margin-bottom: 16px; font-size: 13px; }
  .flash.ok    { background: #d1fae5; color: #065f46; border: 1px solid #6ee7b7; }
  .flash.error { background: #fee2e2; color: #991b1b; border: 1px solid #fca5a5; }
]]

local function layout(prefix, title, body)
    return ([[<!doctype html>
<html lang="en"><head>
  <meta charset="utf-8">
  <title>%s — luamemo</title>
  <style>%s</style>
</head><body>
  <header>
    <strong>luamemo</strong>
    <a href="%s">All memories</a>
  </header>
  <main>%s</main>
</body></html>]]):format(esc(title), CSS, esc(prefix), body)
end

local function render_filter_form(prefix, q, scope, kind, scope_options)
    local opts_html = { '<option value="">All scopes</option>' }
    for _, s in ipairs(scope_options or {}) do
        local sel = (s == scope) and ' selected' or ''
        opts_html[#opts_html + 1] = ('<option value="%s"%s>%s</option>'):format(esc(s), sel, esc(s))
    end
    return ([[<form class="filters" method="get" action="%s">
  <input type="text" name="q" placeholder="Search…" value="%s">
  <select name="scope">%s</select>
  <input type="text" name="kind" placeholder="Kind" value="%s" style="min-width:120px">
  <button type="submit">Search</button>
  <a class="clear" href="%s">Clear</a>
</form>]]):format(esc(prefix), esc(q or ""), table.concat(opts_html), esc(kind or ""), esc(prefix))
end

local function render_list_page(prefix, rows, page, total_pages, ctx)
    ctx = ctx or {}
    local out = { '<h1>Memories</h1>' }
    out[#out + 1] = render_filter_form(prefix, ctx.q, ctx.scope, ctx.kind, ctx.scope_options)
    if ctx.q and ctx.q ~= "" then
        out[#out + 1] = ('<div class="result-meta">Showing top %d hybrid-search results for <strong>%s</strong>%s%s</div>'):format(
            #rows, esc(ctx.q),
            ctx.scope and ctx.scope ~= "" and (' in scope <code>' .. esc(ctx.scope) .. '</code>') or '',
            ctx.kind  and ctx.kind  ~= "" and (' kind <code>' .. esc(ctx.kind)  .. '</code>') or ''
        )
    end
    if not rows or #rows == 0 then
        out[#out + 1] = '<div class="empty">No memories match.</div>'
    else
        out[#out + 1] = [[<table>
<thead><tr>
  <th>ID</th><th>Scope</th><th>Kind</th><th>Title</th><th>Body</th>
  <th class="num">Imp.</th><th class="num">Weight</th><th>Updated</th>
</tr></thead><tbody>]]
        for _, r in ipairs(rows) do
            out[#out + 1] = ([[<tr>
  <td><a class="row" href="%s/%s">%s</a></td>
  <td class="scope">%s</td>
  <td class="kind">%s</td>
  <td>%s</td>
  <td class="body">%s</td>
  <td class="num">%.2f</td>
  <td class="num">%.3f</td>
  <td>%s</td>
</tr>]]):format(
                esc(prefix), esc(r.id), esc(r.id),
                esc(r.scope), esc(r.kind),
                esc(r.title or ""),
                esc((r.body or ""):sub(1, 160)),
                tonumber(r.importance) or 1.0,
                effective_weight(r),
                fmt_age(r.updated_at)
            )
        end
        out[#out + 1] = '</tbody></table>'

        if not ctx.q or ctx.q == "" then
            local q_extra = ''
            if ctx.scope and ctx.scope ~= "" then
                q_extra = q_extra .. '&scope=' .. esc(ctx.scope)
            end
            if ctx.kind and ctx.kind ~= "" then
                q_extra = q_extra .. '&kind=' .. esc(ctx.kind)
            end
            local prev_attr = (page > 1) and "" or ' class="disabled"'
            local next_attr = (page < total_pages) and "" or ' class="disabled"'
            out[#out + 1] = ([[<div class="pager">
  <a href="%s?page=%d%s"%s>&laquo; Prev</a>
  <span>Page %d of %d</span>
  <a href="%s?page=%d%s"%s>Next &raquo;</a>
</div>]]):format(
                esc(prefix), math.max(1, page - 1), q_extra, prev_attr,
                page, total_pages,
                esc(prefix), math.min(total_pages, page + 1), q_extra, next_attr
            )
        end
    end
    return layout(prefix, "Memories", table.concat(out, "\n"))
end

local function dl(label, value)
    return ('<dt>%s</dt><dd>%s</dd>'):format(esc(label), esc(value))
end

local function render_detail_page(prefix, row, ctx)
    ctx = ctx or {}
    local cjson = require("cjson.safe")
    local tags_str   = (row.tags and cjson.encode(row.tags)) or "[]"
    local meta_str   = (row.metadata and cjson.encode(row.metadata)) or "{}"

    local flash = ""
    if ctx.flash then
        flash = ('<div class="flash %s">%s</div>'):format(
            esc(ctx.flash.kind or "ok"), esc(ctx.flash.msg or ""))
    end

    local edit_form = ([[<form class="edit" method="post" action="%s/%s/update">
  <input type="hidden" name="csrf" value="%s">
  <h3 style="margin:0 0 4px;font-size:14px;color:#374151">Edit</h3>
  <label>Title</label>
  <input type="text" name="title" value="%s">
  <label>Body</label>
  <textarea name="body">%s</textarea>
  <div class="row2">
    <div>
      <label>Importance</label>
      <input type="text" name="importance" value="%s">
    </div>
    <div>
      <label>Decay rate</label>
      <input type="text" name="decay_rate" value="%s">
    </div>
  </div>
  <label>Tags (JSON array)</label>
  <input type="text" name="tags" value="%s">
  <label>Metadata (JSON object)</label>
  <input type="text" name="metadata" value="%s">
  <div class="actions-row">
    <button type="submit" class="primary">Save changes</button>
  </div>
</form>
<form method="post" action="%s/%s/delete" onsubmit="return confirm('Delete this memory? This cannot be undone.')" style="margin-top:16px">
  <input type="hidden" name="csrf" value="%s">
  <button type="submit" class="danger">Delete memory</button>
</form>]]):format(
        esc(prefix), esc(row.id), esc(ctx.csrf or ""),
        esc(row.title or ""),
        esc(row.body or ""),
        esc(tostring(tonumber(row.importance) or 1.0)),
        esc(tostring(tonumber(row.decay_rate) or 0.0)),
        esc(tags_str), esc(meta_str),
        esc(prefix), esc(row.id), esc(ctx.csrf or "")
    )

    local body = ([[<div class="detail">
  %s
  <h2>%s</h2>
  <div style="color:#6b7280;font-size:12px;font-family:ui-monospace,monospace">%s</div>
  <dl class="meta-grid">
    %s%s%s%s%s%s%s
  </dl>
  <h3 style="margin:24px 0 8px;font-size:14px;color:#374151">Body</h3>
  <div class="body-block">%s</div>
  <h3 style="margin:24px 0 8px;font-size:14px;color:#374151">Tags</h3>
  <div class="json-block">%s</div>
  <h3 style="margin:24px 0 8px;font-size:14px;color:#374151">Metadata</h3>
  <div class="json-block">%s</div>
  %s
</div>]]):format(
        flash,
        esc(row.title or "(untitled)"),
        esc(row.id),
        dl("scope",       row.scope),
        dl("kind",        row.kind),
        dl("importance",  tostring(tonumber(row.importance) or 1.0)),
        dl("decay_rate",  tostring(tonumber(row.decay_rate) or 0.0)),
        dl("eff. weight", string.format("%.4f", effective_weight(row))),
        dl("created_at",  row.created_at),
        dl("updated_at",  row.updated_at),
        esc(row.body or ""),
        esc(tags_str),
        esc(meta_str),
        edit_form
    )
    return layout(prefix, row.title or "Memory", body)
end

-- ---------------------------------------------------------------------------
-- registration
-- ---------------------------------------------------------------------------
function M.register(app, opts)
    opts = opts or {}
    local prefix   = opts.prefix or "/memory/ui"
    local per_page = math.max(1, math.min(200, tonumber(opts.per_page) or 25))
    local store    = require("luamemo.store")

    -- GET /  (list, optionally filtered/searched)
    app:get(prefix, function(self)
        local denied = authorise(self); if denied then return denied end
        local p = self.params or {}
        local q     = (p.q     and p.q     ~= "") and p.q     or nil
        local scope = (p.scope and p.scope ~= "") and p.scope or nil
        local kind  = (p.kind  and p.kind  ~= "") and p.kind  or nil
        local page  = math.max(1, tonumber(p.page) or 1)

        local db    = require("lapis.db")
        local cjson = require("cjson.safe")
        local cfg   = get_cfg()
        local tbl   = cfg.db_table or "lapis_memory"

        -- Distinct scopes for the dropdown (cap to keep page light).
        local scope_rows = db.query(
            "SELECT DISTINCT scope FROM " .. tbl ..
            " ORDER BY scope LIMIT 200") or {}
        local scope_options = {}
        for _, r in ipairs(scope_rows) do scope_options[#scope_options + 1] = r.scope end

        local rows, total_pages = {}, 1
        if q then
            -- Hybrid search path; ignores pagination (top-N is the result).
            local hits = store.search({
                query = q, scope = scope, kind = kind,
                limit = math.min(per_page * 2, 100),
                ignore_decay = false,
            }) or {}
            rows = hits
        else
            -- Browse path with optional scope/kind filter + pagination.
            local where_parts = {}
            if scope then where_parts[#where_parts + 1] = "scope = " .. db.escape_literal(scope) end
            if kind  then where_parts[#where_parts + 1] = "kind  = " .. db.escape_literal(kind)  end
            local where = (#where_parts > 0) and ("WHERE " .. table.concat(where_parts, " AND ")) or ""
            local total_row = db.query("SELECT COUNT(*) AS n FROM " .. tbl .. " " .. where)
            local total = (total_row and total_row[1] and tonumber(total_row[1].n)) or 0
            total_pages = math.max(1, math.ceil(total / per_page))
            if page > total_pages then page = total_pages end
            rows = db.query(([[
                SELECT id, scope, kind, title, body, tags, metadata,
                       importance, decay_rate, created_at, updated_at
                FROM %s %s
                ORDER BY created_at DESC
                LIMIT %d OFFSET %d
            ]]):format(tbl, where, per_page, (page - 1) * per_page)) or {}
        end
        for _, r in ipairs(rows) do
            if type(r.tags) == "string" then r.tags = cjson.decode(r.tags) end
            if type(r.metadata) == "string" then r.metadata = cjson.decode(r.metadata) end
        end
        return {
            content_type = "text/html; charset=utf-8",
            layout = false,
            render_list_page(prefix, rows, page, total_pages, {
                q = q, scope = scope, kind = kind, scope_options = scope_options,
            }),
        }
    end)

    -- GET /:id  (detail)
    app:get(prefix .. "/:id", function(self)
        local denied = authorise(self); if denied then return denied end
        local row = store.get(self.params.id)
        if not row then
            return { status = 404, content_type = "text/plain", "not found" }
        end
        local csrf = ensure_csrf(self)
        local flash
        if self.params.flash == "saved" then
            flash = { kind = "ok", msg = "Saved." }
        elseif self.params.flash and self.params.flash:sub(1, 6) == "error:" then
            flash = { kind = "error", msg = self.params.flash:sub(7) }
        end
        return {
            content_type = "text/html; charset=utf-8",
            layout = false,
            render_detail_page(prefix, row, { csrf = csrf, flash = flash }),
        }
    end)

    -- POST /:id/update
    app:post(prefix .. "/:id/update", function(self)
        local denied = authorise(self); if denied then return denied end
        local cfail = check_csrf(self); if cfail then return cfail end
        local cjson = require("cjson.safe")
        local p = self.params or {}
        local patch = {
            title = p.title,
            body  = p.body,
        }
        if p.importance and p.importance ~= "" then
            patch.importance = tonumber(p.importance)
        end
        if p.decay_rate and p.decay_rate ~= "" then
            patch.decay_rate = tonumber(p.decay_rate)
        end
        if p.tags and p.tags ~= "" then
            local t, terr = cjson.decode(p.tags)
            if not t then
                return { redirect_to = prefix .. "/" .. self.params.id ..
                    "?flash=error:invalid+tags+JSON" }
            end
            patch.tags = t
        end
        if p.metadata and p.metadata ~= "" then
            local m, merr = cjson.decode(p.metadata)
            if not m then
                return { redirect_to = prefix .. "/" .. self.params.id ..
                    "?flash=error:invalid+metadata+JSON" }
            end
            patch.metadata = m
        end
        local _, err = store.update(self.params.id, patch)
        if err then
            return { redirect_to = prefix .. "/" .. self.params.id ..
                "?flash=error:" .. (err:gsub(" ", "+")) }
        end
        return { redirect_to = prefix .. "/" .. self.params.id .. "?flash=saved" }
    end)

    -- POST /:id/delete
    app:post(prefix .. "/:id/delete", function(self)
        local denied = authorise(self); if denied then return denied end
        local cfail = check_csrf(self); if cfail then return cfail end
        store.delete(self.params.id)
        return { redirect_to = prefix }
    end)
end

return M
