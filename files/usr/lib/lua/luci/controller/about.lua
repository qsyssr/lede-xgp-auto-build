--[[
LuCI about menu by zzzz0317 for XiGuaPi V3 <https://github.com/zzzz0317/lede-xgp-auto-build/>
]]--
module("luci.controller.about", package.seeall)

function index()
    local page = node("admin", "about")
    page.title = _("关于")
    page.order = 90
    page.sysauth = "root"
    page.sysauth_authenticator = "htmlauth"
    page.index = true
    
    page = node("admin", "about", "github")
    page.title = _("⭐ 固件发布")
    page.target = call("action_zz_github")
    page.order = 10
    
    page = node("admin", "about", "support")
    page.title = _("👍 一键三连")
    page.target = call("action_zz_bilibili")
    page.order = 20
end

function action_zz_github()
    luci.http.redirect("https://github.com/zzzz0317/lede-xgp-auto-build/")
end

function action_zz_bilibili()
    luci.http.redirect("https://www.bilibili.com/video/BV1dU31ziEQf/")
end
