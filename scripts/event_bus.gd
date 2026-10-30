extends Node

# 全局事件总线（Autoload：EventBus）
# 玩法系统只负责“发生了一件事”，教程等引导/UI 逻辑订阅这些信号，
# 两边互不直接引用，避免教程逻辑散落在角色与道具脚本里。

signal item_picked_up(item_name: String)   # 拾取了道具（item_name：石头 / 南瓜）
signal item_thrown(item_name: String)      # 道具脱手掷出的瞬间
signal dummy_hit                           # 教程假人被投掷物砸中
signal slow_zone_avoided                   # 未被减速地走过减速区触发区
signal skill_used                          # 玩家释放了主动技能
