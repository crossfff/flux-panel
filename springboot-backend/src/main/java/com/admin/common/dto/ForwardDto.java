package com.admin.common.dto;

import com.baomidou.mybatisplus.annotation.FieldStrategy;
import com.baomidou.mybatisplus.annotation.TableField;
import lombok.Data;
import javax.validation.constraints.NotBlank;
import javax.validation.constraints.NotNull;
import javax.validation.constraints.Min;
import javax.validation.constraints.Max;

@Data
public class ForwardDto {

    @NotBlank(message = "转发名称不能为空")
    private String name;
    
    @NotNull(message = "隧道ID不能为空")
    private Integer tunnelId;
    
    /**
     * 远程地址（普通转发必填；端口复用模式下可为空，由 rules 决定目标）
     */
    private String remoteAddr;

    private String strategy;
    
    /**
     * 入口端口（可选，为空时自动分配）
     */
    @Min(value = 1, message = "端口号不能小于1")
    @Max(value = 65535, message = "端口号不能大于65535")
    private Integer inPort;

    private String interfaceName;


    /**
     * 转发模式：0-普通转发（默认），1-端口复用
     */
    private Integer mode;

    /**
     * 端口复用兜底目标 ip:port
     */
    private String fallbackAddr;

    /**
     * 端口复用规则列表（mode=1 时必填）
     */
    private java.util.List<ForwardRuleDto> rules;

} 