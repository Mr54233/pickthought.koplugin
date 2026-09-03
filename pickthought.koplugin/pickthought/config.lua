local C = {
    NAME = "撷思",
    VERSION = "0.4.2",
    SCHEMA = 1,
    PLUGIN_DIR = "pickthought.koplugin",
    DATA_DIR = "pickthought",

    -- 想法弹窗尺寸统一配置:默认值用于新安装和“恢复默认尺寸”,限制用于
    -- 设置归一化、弹窗构造和设置菜单,避免不同入口使用不同边界。
    THOUGHT_POPUP_DEFAULTS = {
        width_ratio = 0.90,
        height_ratio = 0.80,
    },
    THOUGHT_POPUP_LIMITS = {
        min_width_ratio = 0.60,
        max_width_ratio = 1.00,
        min_height_ratio = 0.50,
        max_height_ratio = 0.90,
        ratio_step = 5,
    },

    -- 更新清单固定保存在仓库根目录；清单中的下载地址指向
    -- GitHub Release 全量包。旧版本仍可通过备用地址升级到本版本。
    UPDATE_MANIFEST = "https://raw.githubusercontent.com/Mr54233/pickthought.koplugin/main/update.json",
    UPDATE_MANIFESTS = {
        "https://raw.githubusercontent.com/Mr54233/pickthought.koplugin/main/update.json",
    },

    -- 仅作为 GitHub 官方资源访问失败时的回退入口。
    -- 下载后仍会执行大小与 SHA-256 校验，镜像不能改变安装内容。
    GITHUB_MIRRORS = {
        "https://ghfast.top/",
        "https://gh-proxy.com/",
        "https://ghproxy.net/",
    },

    AUTO_UPDATE_INTERVAL = 24 * 60 * 60,
    AUTO_UPDATE_RETRY_INTERVAL = 6 * 60 * 60,
    LOW_MEMORY_SETTING = "DGLOBAL_CACHE_FREE_PROPORTION",
    LOW_MEMORY_RATIO = 0.15,
    READ_INTERVAL = 30,
    IDLE_TIMEOUT = 600,
    REMOTE_THRESHOLD = 2,
}
return C
