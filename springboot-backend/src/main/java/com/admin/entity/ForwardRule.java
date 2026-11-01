package com.admin.entity;

import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;
import lombok.EqualsAndHashCode;

/**
 * <p>
 * 端口复用规则实体类
 * </p>
 */
@Data
@EqualsAndHashCode(callSuper = true)
@TableName("forward_rule")
public class ForwardRule extends BaseEntity {

    private static final long serialVersionUID = 1L;

    /**
     * 所属转发ID
     */
    private Integer forwardId;

    /**
     * 匹配类型：sni（TLS 的 SNI）或 host（HTTP 的 Host）
     */
    private String matchType;

    /**
     * 匹配值，支持精确匹配和 *.example.com 通配
     */
    private String matchValue;

    /**
     * 目标地址 ip:port
     */
    private String targetAddr;

    /**
     * 备注
     */
    private String remark;

    /**
     * 入站流量
     */
    private Long inFlow;

    /**
     * 出站流量
     */
    private Long outFlow;
}