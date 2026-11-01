package com.admin.entity;

import java.io.Serializable;
import lombok.Data;
import lombok.EqualsAndHashCode;

/**
 * <p>
 * 
 * </p>
 *
 * @author QAQ
 * @since 2025-06-03
 */
@Data
@EqualsAndHashCode(callSuper = false)
public class Forward extends BaseEntity{

    private static final long serialVersionUID = 1L;

    private Integer userId;

    private String userName;

    private String name;

    private Integer tunnelId;

    private Integer inPort;

    private Integer outPort;

    private String remoteAddr;

    private String interfaceName;

    private String strategy;

    private Long inFlow;

    private Long outFlow;

    private Integer inx;

    /**
     * 转发模式：0-普通转发（默认），1-端口复用（单入口端口按 SNI/Host 分流多目标）
     */
    private Integer mode;

    /**
     * 端口复用时的兜底目标（无 SNI/Host 线索时使用）
     */
    private String fallbackAddr;

}
