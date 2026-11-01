package com.admin.common.dto;

import lombok.Data;

import javax.validation.constraints.NotBlank;

@Data
public class ForwardRuleDto {

    /**
     * 匹配类型：sni | host
     */
    private String matchType;

    /**
     * 匹配值，如 a.example.com 或 *.example.com
     */
    @NotBlank(message = "匹配值不能为空")
    private String matchValue;

    /**
     * 目标地址 ip:port
     */
    @NotBlank(message = "目标地址不能为空")
    private String targetAddr;

    private String remark;
}
