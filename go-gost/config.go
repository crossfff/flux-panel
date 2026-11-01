package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// PanelConfig 一个面板对接端点。
// Prefix 用于给该面板下发的服务/链/限流器名称加前缀，
// 避免同一节点同时对接多个面板时出现同名冲突（默认不加前缀）。
type PanelConfig struct {
	Addr   string `json:"addr"`
	Secret string `json:"secret"`
	Prefix string `json:"prefix"`
}

// Config 配置结构体
type Config struct {
	Addr   string `json:"addr"`
	Secret string `json:"secret"`
	Http   int    `json:"http"`
	Tls    int    `json:"tls"`
	Socks  int    `json:"socks"`

	// Panels 额外对接的面板列表（可选）。
	// 主面板仍用 addr/secret，这里可以再挂载任意多个。
	Panels []PanelConfig `json:"panels"`
}

// Endpoints 返回本节点需要对接的全部面板（主面板在首位）
func (c *Config) Endpoints() []PanelConfig {
	eps := make([]PanelConfig, 0, len(c.Panels)+1)
	if strings.TrimSpace(c.Addr) != "" {
		eps = append(eps, PanelConfig{Addr: c.Addr, Secret: c.Secret})
	}
	for _, p := range c.Panels {
		if strings.TrimSpace(p.Addr) != "" && strings.TrimSpace(p.Secret) != "" {
			eps = append(eps, p)
		}
	}
	return eps
}

// LoadConfig 加载配置文件
func LoadConfig(configPath string) (*Config, error) {
	// 检查文件是否存在
	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		return nil, fmt.Errorf("配置文件不存在: %s", configPath)
	}

	// 读取文件内容
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("读取配置文件失败: %v", err)
	}

	// 解析JSON
	var config Config
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("解析配置文件失败: %v", err)
	}

	// 验证必要的配置项：至少要有一个可用的面板
	if config.Addr == "" && len(config.Panels) == 0 {
		return nil, fmt.Errorf("服务器地址不能为空")
	}
	if config.Addr != "" && config.Secret == "" {
		return nil, fmt.Errorf("密钥不能为空")
	}

	// 校验附加面板
	for i, p := range config.Panels {
		if strings.TrimSpace(p.Addr) == "" {
			return nil, fmt.Errorf("panels[%d] 的地址不能为空", i)
		}
		if strings.TrimSpace(p.Secret) == "" {
			return nil, fmt.Errorf("panels[%d] 的密钥不能为空", i)
		}
	}

	if len(config.Endpoints()) == 0 {
		return nil, fmt.Errorf("没有可用的面板对接配置")
	}

	return &config, nil
}