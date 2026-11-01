-- ============================================================
-- 端口复用（单入口端口按 SNI / Host 分流多目标）升级脚本
-- 适用于已部署的 flux-panel 实例
-- 执行前请备份数据库
-- ============================================================

-- 1) forward 表增加模式与兜底字段
ALTER TABLE `forward`
  ADD COLUMN `mode` int(10) NOT NULL DEFAULT 0 COMMENT '转发模式：0-普通转发 1-端口复用',
  ADD COLUMN `fallback_addr` varchar(255) DEFAULT NULL COMMENT '端口复用兜底目标，如 10.0.0.5:443';

-- 2) 新建分流规则表
CREATE TABLE IF NOT EXISTS `forward_rule` (
  `id` int(10) NOT NULL AUTO_INCREMENT,
  `forward_id` int(10) NOT NULL COMMENT '所属转发ID',
  `match_type` varchar(16) NOT NULL DEFAULT 'sni' COMMENT '匹配类型：sni / host',
  `match_value` varchar(255) NOT NULL COMMENT '匹配值，支持 *.example.com 通配',
  `target_addr` varchar(255) NOT NULL COMMENT '目标地址 ip:port',
  `remark` varchar(255) DEFAULT NULL,
  `in_flow` bigint(20) NOT NULL DEFAULT '0',
  `out_flow` bigint(20) NOT NULL DEFAULT '0',
  `created_time` bigint(20) NOT NULL,
  `updated_time` bigint(20) NOT NULL,
  `status` int(10) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`),
  KEY `idx_forward` (`forward_id`),
  KEY `idx_match` (`match_value`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='端口复用分流规则';