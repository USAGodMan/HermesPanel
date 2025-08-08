package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"hermes/proto"
	"io"
	"net/http"

	"hash/fnv"
	mrand "math/rand"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/disk"
	"github.com/shirou/gopsutil/v3/host"
	"github.com/shirou/gopsutil/v3/mem"
	psnet "github.com/shirou/gopsutil/v3/net"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/transform"
	"golang.org/x/time/rate"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
)

const udpSessionShards = 256 // 定义分片数量，256是一个比较合理的值

type udpSession struct {
		remoteConn   net.Conn
		lastActivity atomic.Value
}

// udpSessionShard 包含一个锁和用于存储会话的map
type udpSessionShard struct {
	sync.Mutex
	sessions map[string]*udpSession
}

// fnv1a 是一个简单高效的非加密哈希函数，用于将key分散到不同分片
func fnv1a(s string) uint32 {
	h := fnv.New32a()
	h.Write([]byte(s))
	return h.Sum32()
}


var bufferPool = sync.Pool{
	New: func() interface{} {
		b := make([]byte, 32*1024)
		return &b
	},
}

type Config struct {
	BackendAddress string `json:"backend_address"`
	SecretKey      string `json:"secret_key"`
	ReportInterval int    `json:"report_interval"`
	LogLevel       string `json:"log_level"`
	LogFormat      string `json:"log_format"`
	CACertPath     string `json:"ca_cert_path"` // 用于验证后端服务器的 CA 证书路径
	InsecureSkipVerify bool   `json:"insecure_skip_verify"` // 跳过后端服务器证书验证
}

type Forwarder struct {
	Rule         *proto.Rule
	uploadLimiter   *rate.Limiter
	downloadLimiter *rate.Limiter
	PacketConn   net.PacketConn
	cancel       context.CancelFunc
	activeConns  atomic.Int32
	Listener     net.Listener
	udpReplyJobs chan udpReplyJob
	udpWg        sync.WaitGroup
	healthStatus     *TargetHealthStatus // 用于维护所有目标的健康状态
	healthCheckCancel context.CancelFunc    // 用于独立地停止健康检查 goroutine
	wrrState     *WRRState // 用于平滑加权轮询的状态
	wrrStateMu   sync.Mutex
	targetActiveConns   *sync.Map     // 用于最少连接数策略, map[string]*atomic.Int32
}

// 用于存储平滑加权轮询状态的结构体
type WRRState struct {
	Targets       []WRRTarget
	TotalWeight   int32
	gcd           int32 // 所有权重的最大公约数
	maxWeight     int32 // 所有权重中的最大值
	currentIndex  int   // 当前选择的索引
	currentWeight int32 // 当前权重
}

// 平滑加权轮询的目标结构体
type WRRTarget struct {
	Address         string
	EffectiveWeight int32 // 实时有效权重
	Weight          int32 // 原始配置权重
}

// 用于安全地管理目标的健康状态和计数器
type TargetHealthStatus struct {
	mu           sync.RWMutex
	status       map[string]bool            // key: "ip:port", value: isHealthy
	failureCount map[string]int32           // key: "ip:port", value: consecutive failures
	successCount map[string]int32           // key: "ip:port", value: consecutive successes
}

// TargetHealthStatus 的构造函数
func NewTargetHealthStatus(targets []string) *TargetHealthStatus {
	ths := &TargetHealthStatus{
		status:       make(map[string]bool),
		failureCount: make(map[string]int32),
		successCount: make(map[string]int32),
	}
	// 初始状态下，所有目标都认为是健康的
	for _, target := range targets {
		ths.status[target] = true
	}
	return ths
}

type udpReplyJob struct {
	remoteConn net.Conn
	clientAddr net.Addr
	stats      *ruleTraffic
	onClose    func()
}

type ruleTraffic struct {
	inbound  atomic.Int64
	outbound atomic.Int64
}

type ForwarderManager struct {
	sync.RWMutex
	tasks map[int64]*Forwarder
}

type TrafficManager struct {
	sync.RWMutex
	stats map[int64]*ruleTraffic
}

type Agent struct {
	config               *Config
	nodeID               int64
	grpcConn             *grpc.ClientConn
	grpcClient           proto.NodeServiceClient
	tunnelTLSConfig      *tls.Config
	forwarderManager     *ForwarderManager
	trafficManager       *TrafficManager
	egressGroupsMu       sync.RWMutex
	egressGroups         map[int64]*proto.ServerList
	roundRobinCounters   sync.Map 
	lastNetStats         []psnet.IOCountersStat
	lastNetStatTime      time.Time
	netStatsLock         sync.Mutex
	ctx                  context.Context
	cancel               context.CancelFunc
	tunnelListenPort     int
	ruleStatusUpdateChan chan *proto.ClientToServerMessage
}

type latencyTarget struct {
	Name string
	Addr string
}

func NewForwarderManager() *ForwarderManager {
	return &ForwarderManager{tasks: make(map[int64]*Forwarder)}
}

func (m *ForwarderManager) Add(fw *Forwarder) {
	m.Lock()
	m.tasks[fw.Rule.RuleId] = fw
	m.Unlock()
}

func (m *ForwarderManager) Get(ruleID int64) (*Forwarder, bool) {
	m.RLock()
	fw, ok := m.tasks[ruleID]
	m.RUnlock()
	return fw, ok
}

func (m *ForwarderManager) Remove(ruleID int64) (*Forwarder, bool) {
	m.Lock()
	if fw, ok := m.tasks[ruleID]; ok {
		delete(m.tasks, ruleID)
		m.Unlock()
		return fw, true
	}
	m.Unlock()
	return nil, false
}

func (m *ForwarderManager) StopAll() {
	m.Lock()
	for id, fw := range m.tasks {
		fw.cancel()
		if fw.Listener != nil {
			fw.Listener.Close()
		}
		if fw.PacketConn != nil {
			fw.PacketConn.Close()
		}
		delete(m.tasks, id)
	}
	m.Unlock()
}

func (m *ForwarderManager) TotalConnections() int64 {
	m.RLock()
	var total int64
	for _, fw := range m.tasks {
		total += int64(fw.activeConns.Load())
	}
	m.RUnlock()
	return total
}

func NewTrafficManager() *TrafficManager {
	return &TrafficManager{stats: make(map[int64]*ruleTraffic)}
}

func (m *TrafficManager) Register(ruleID int64) {
	m.Lock()
	m.stats[ruleID] = &ruleTraffic{}
	m.Unlock()
}

func (m *TrafficManager) Unregister(ruleID int64) {
	m.Lock()
	delete(m.stats, ruleID)
	m.Unlock()
}

func (m *TrafficManager) GetAndResetAll() []*proto.TrafficStat {
	m.Lock()
	statsToSend := make([]*proto.TrafficStat, 0, len(m.stats))
	for id, stat := range m.stats {
		in := stat.inbound.Swap(0)
		out := stat.outbound.Swap(0)
		if in > 0 || out > 0 {
			statsToSend = append(statsToSend, &proto.TrafficStat{
				RuleId: id, InboundBytes: in, OutboundBytes: out,
			})
		}
	}
	m.Unlock()
	return statsToSend
}

func (m *TrafficManager) GetStats(ruleID int64) (*ruleTraffic, bool) {
	m.RLock()
	s, ok := m.stats[ruleID]
	m.RUnlock()
	return s, ok
}

// 启动健康检查的主循环
func (a *Agent) startHealthChecker(fw *Forwarder) {
	if fw.Rule == nil || fw.Rule.HealthCheckConfig == nil || fw.Rule.HealthCheckConfig.Interval <= 0 {
		return
	}

	cfg := fw.Rule.HealthCheckConfig
	interval := time.Duration(cfg.Interval) * time.Second

	var healthCheckCtx context.Context
	healthCheckCtx, fw.healthCheckCancel = context.WithCancel(a.ctx)

	go func() {
		logger := zap.L().With(zap.Int64("规则ID", fw.Rule.RuleId))
		logger.Info("健康检查器已启动", zap.Duration("检查间隔", interval))

		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		for _, addr := range fw.Rule.RemoteAddresses {
			go a.performSingleCheck(fw, addr)
		}

		for {
			select {
			case <-healthCheckCtx.Done():
				logger.Info("健康检查器已停止。")
				return
			case <-ticker.C:
				for _, addr := range fw.Rule.RemoteAddresses {
					go a.performSingleCheck(fw, addr)
				}
			}
		}
	}()
}

func (a *Agent) performSingleCheck(fw *Forwarder, addr string) {
	cfg := fw.Rule.HealthCheckConfig
	logger := zap.L().With(zap.Int64("规则ID", fw.Rule.RuleId), zap.String("目标", addr))

	var isSuccess bool
	checkTimeout := time.Duration(cfg.Timeout) * time.Second

	switch cfg.Type {
	case "tcp":
		conn, err := net.DialTimeout("tcp", addr, checkTimeout)
		if err == nil {
			conn.Close()
			isSuccess = true
		}
	case "http_get":
		host, _, _ := net.SplitHostPort(addr)
		path := cfg.Path
		if path == "" {
			path = "/"
		} else if !strings.HasPrefix(path, "/") {
			path = "/" + path
		}

		url := fmt.Sprintf("http://%s:%d%s", host, cfg.Port, path)

		client := http.Client{Timeout: checkTimeout}
		resp, err := client.Get(url)
		if err == nil {
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			if resp.StatusCode >= 200 && resp.StatusCode < 400 {
				isSuccess = true
			}
		}
	default:
		logger.Warn("不支持的健康检查类型", zap.String("类型", cfg.Type))
		return
	}

	hs := fw.healthStatus
	hs.mu.Lock()
	defer hs.mu.Unlock()

	if isSuccess {
		hs.failureCount[addr] = 0
		hs.successCount[addr]++

		if !hs.status[addr] && hs.successCount[addr] >= int32(cfg.HealthyThreshold) {
			hs.status[addr] = true
			logger.Warn("目标节点恢复健康")
			a.SendRuleOperationalStatus(fw.Rule.RuleId, "active", fmt.Sprintf("目标 %s 恢复健康", addr))
		}
	} else {
		hs.successCount[addr] = 0
		hs.failureCount[addr]++

		if hs.status[addr] && hs.failureCount[addr] >= int32(cfg.UnhealthyThreshold) {
			hs.status[addr] = false
			logger.Warn("目标节点变为不健康")
			a.SendRuleOperationalStatus(fw.Rule.RuleId, "degraded", fmt.Sprintf("目标 %s 变为不健康", addr))
		}
	}
}

func NewAgent(config *Config) (*Agent, error) {
	ctx, cancel := context.WithCancel(context.Background())

	tlsConfig, err := setupTunnelMTLS(config)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("初始化隧道 mTLS 配置失败: %w", err)
	}

	return &Agent{
		config:               config,
		forwarderManager:     NewForwarderManager(),
		trafficManager:       NewTrafficManager(),
		tunnelTLSConfig:      tlsConfig,
		ctx:                  ctx,
		cancel:               cancel,
		egressGroups:         make(map[int64]*proto.ServerList),
		ruleStatusUpdateChan: make(chan *proto.ClientToServerMessage, 100),
	}, nil
}

func (a *Agent) Run() error {
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sigChan; a.cancel() }()
	backoff := 1 * time.Second
	maxBackoff := 1 * time.Minute
	for {
		select {
		case <-a.ctx.Done():
			a.shutdown()
			return nil
		default:
		}
		err := a.connectAndSync()
		if err != nil {
			zap.L().Error("连接和同步失败，将在稍后重试", zap.Error(err))
			select {
			case <-time.After(backoff):
				backoff = min(backoff*2, maxBackoff)
			case <-a.ctx.Done():
			}
		} else {
			backoff = 1 * time.Second
		}
	}
}

func (a *Agent) shutdown() {
	a.forwarderManager.StopAll()
	if a.grpcConn != nil {
		a.grpcConn.Close()
	}
}

func (a *Agent) connectAndSync() error {
	var creds credentials.TransportCredentials
	var err error

	if a.config.InsecureSkipVerify {
		zap.L().Warn("以【不安全】gRPC 模式启动。将不会验证服务器证书。")
		creds = credentials.NewTLS(&tls.Config{
			InsecureSkipVerify: true,
		})
	} else {
		zap.L().Info("以【安全】gRPC 模式启动。将使用提供的 CA 验证服务器证书。")
		creds, err = credentials.NewClientTLSFromFile(a.config.CACertPath, extractApiHost(a.config.BackendAddress))
		if err != nil {
			return fmt.Errorf("无法从 '%s' 加载 CA 证书: %w", a.config.CACertPath, err)
		}
	}

	conn, err := grpc.DialContext(a.ctx, a.config.BackendAddress,
		grpc.WithTransportCredentials(creds),
		grpc.WithBlock(),
	)
	if err != nil {
		return fmt.Errorf("连接 gRPC 服务器失败: %w", err)
	}
	a.grpcConn = conn
	defer conn.Close()
	a.grpcClient = proto.NewNodeServiceClient(conn)
	zap.L().Info("已成功连接到 gRPC 后端", zap.String("地址", a.config.BackendAddress))

	if err := a.register(); err != nil {
		return fmt.Errorf("Agent 注册失败: %w", err)
	}

	md := metadata.New(map[string]string{
		"node-id":    fmt.Sprintf("%d", a.nodeID),
		"secret-key": a.config.SecretKey,
	})
	streamCtx := metadata.NewOutgoingContext(a.ctx, md)
	stream, err := a.grpcClient.Sync(streamCtx)
	if err != nil {
		return fmt.Errorf("建立 gRPC 同步流失败: %w", err)
	}
	zap.L().Info("gRPC 同步流已建立")

	var wg sync.WaitGroup
	wg.Add(2)
	var recvErr, sendErr error
	go func() { defer wg.Done(); sendErr = a.sendReports(stream) }()
	go func() { defer wg.Done(); recvErr = a.receiveMessages(stream) }()
	wg.Wait()

	a.forwarderManager.StopAll()

	if recvErr != nil && !errors.Is(recvErr, io.EOF) {
		return fmt.Errorf("消息接收循环异常退出: %w", recvErr)
	}
	if sendErr != nil {
		return fmt.Errorf("报告发送循环异常退出: %w", sendErr)
	}
	return nil
}

func (a *Agent) register() error {
	logger := zap.L().With(zap.String("组件", "注册"))
	ctx, cancel := context.WithTimeout(a.ctx, 10*time.Second)
	defer cancel()
	regReq := &proto.RegisterRequest{
		SecretKey:  a.config.SecretKey,
		SystemInfo: collectSystemInfo(),
	}
	regRes, err := a.grpcClient.Register(ctx, regReq)
	if err != nil {
		logger.Error("注册请求失败", zap.Error(err))
		return fmt.Errorf("向后端注册失败: %w", err)
	}
	if !regRes.Success {
		logger.Error("后端拒绝注册", zap.String("错误信息", regRes.ErrorMessage))
		return fmt.Errorf("注册失败: %s", regRes.ErrorMessage)
	}
	a.nodeID = regRes.NodeId
	logger.Info("注册成功", zap.Int64("节点ID", a.nodeID))
	if regRes.TunnelListenPort > 0 {
		if a.tunnelListenPort != int(regRes.TunnelListenPort) {
			a.tunnelListenPort = int(regRes.TunnelListenPort)
			go a.startTunnelServer()
		}
	}
	return nil
}

func (a *Agent) receiveMessages(stream proto.NodeService_SyncClient) error {
	logger := zap.L().With(zap.String("组件", "接收消息"))
	for {
		select {
		case <-a.ctx.Done():
			logger.Info("Agent 上下文已取消，停止接收消息")
			return a.ctx.Err()
		default:
		}
		res, err := stream.Recv()
		if err != nil {
			logger.Error("接收消息失败", zap.Error(err))
			return err
		}
		switch payload := res.Payload.(type) {
		case *proto.ServerToClientMessage_RuleUpdateRequest:
			updateRequest := payload.RuleUpdateRequest
			if updateRequest == nil {
				logger.Warn("收到空的规则更新请求")
				break
			}
			a.egressGroupsMu.Lock()
			for groupID, serverList := range updateRequest.GetEgressServerGroups() {
				a.egressGroups[groupID] = serverList
			}
			a.egressGroupsMu.Unlock()
			logger.Info("收到规则更新", zap.Int("规则数量", len(updateRequest.GetRules())))
			a.handleRuleUpdate(updateRequest.GetRules())
		case *proto.ServerToClientMessage_LatencyTestRequest:
			go a.handleLatencyTestRequest(payload.LatencyTestRequest, stream)
		}
	}
}

func (a *Agent) handleLatencyTestRequest(req *proto.LatencyTestRequest, stream proto.NodeService_SyncClient) {
	logger := zap.L().With(zap.Int64("规则ID", req.RuleId))
	logger.Info("收到延迟测试请求，开始并行 PING...")

	var wg sync.WaitGroup
	wg.Add(2)

	var entryPingResult, exitPingResult *proto.PingResult
	var entryErr, exitErr error

	go func() {
		defer wg.Done()
		if req.PublicIpToPing != "" {
			logger.Info("正在执行入口 PING...", zap.String("目标IP", req.PublicIpToPing))
			entryPingResult = performPing(req.PublicIpToPing)
			if !entryPingResult.GetSuccess() {
				entryErr = fmt.Errorf("入口 PING 失败: %s", entryPingResult.GetErrorMessage())
			}
		} else {
			entryPingResult = &proto.PingResult{ErrorMessage: "未提供用于入口 PING 的公网 IP。", Success: false}
			entryErr = errors.New(entryPingResult.ErrorMessage)
		}
	}()

	go func() {
		defer wg.Done()
		a.forwarderManager.RLock()
		fw, ok := a.forwarderManager.tasks[req.RuleId]
		a.forwarderManager.RUnlock()

		if ok && fw.Rule != nil && len(fw.Rule.GetRemoteAddresses()) > 0 {
			exitPingTarget := fw.Rule.GetRemoteAddresses()[0]
			var host string
			if strings.Contains(exitPingTarget, ":") {
				var err error
				host, _, err = net.SplitHostPort(exitPingTarget)
				if err != nil {
					host = exitPingTarget
				}
			} else {
				host = exitPingTarget
			}
			logger.Info("正在执行出口 PING...", zap.String("目标主机", host))
			exitPingResult = performPing(host)
			if !exitPingResult.GetSuccess() {
				exitErr = fmt.Errorf("出口 PING 失败: %s", exitPingResult.GetErrorMessage())
			}
		} else {
			exitPingResult = &proto.PingResult{ErrorMessage: "规则未找到或没有可用于出口 PING 的远程地址。", Success: false}
			exitErr = errors.New(exitPingResult.ErrorMessage)
		}
	}()

	wg.Wait()
	logger.Info("入口和出口 PING 均已完成。")

	testResult := &proto.LatencyTestResult{
		RuleId:          req.RuleId,
		Timestamp:       time.Now().Format(time.RFC3339),
		EntryPingResult: entryPingResult,
		ExitPingResult:  exitPingResult,
		Success:         entryErr == nil && exitErr == nil,
	}
	if !testResult.Success {
		var errs []string
		if entryErr != nil {
			errs = append(errs, entryErr.Error())
		}
		if exitErr != nil {
			errs = append(errs, exitErr.Error())
		}
		testResult.ErrorMessage = strings.Join(errs, " | ")
		logger.Error("延迟测试完成，但有错误发生", zap.String("错误", testResult.ErrorMessage))
	} else {
		logger.Info("延迟测试成功完成")
	}

	msg := &proto.ClientToServerMessage{
		Payload: &proto.ClientToServerMessage_LatencyTestResult{
			LatencyTestResult: testResult,
		},
	}
	if err := stream.Send(msg); err != nil {
		logger.Error("发送延迟测试结果失败", zap.Error(err))
	}
}

func (a *Agent) sendReports(stream proto.NodeService_SyncClient) error {
	logger := zap.L().With(zap.String("组件", "发送报告"))
	ticker := time.NewTicker(time.Duration(a.config.ReportInterval) * time.Second)
	defer ticker.Stop()
	if err := a.sendReportPayloads(stream); err != nil {
		logger.Warn("发送初始周期性报告失败", zap.Error(err))
		return err
	}
	for {
		select {
		case msg := <-a.ruleStatusUpdateChan:
			if err := stream.Send(msg); err != nil {
				logger.Warn("发送规则状态更新失败",
					zap.Int64("规则ID", msg.GetRuleStatusUpdate().GetRuleId()),
					zap.String("状态", msg.GetRuleStatusUpdate().GetStatus()),
					zap.Error(err))
				return err
			}
		case <-ticker.C:
			if err := a.sendReportPayloads(stream); err != nil {
				logger.Warn("发送周期性报告失败", zap.Error(err))
				return err
			}
		case <-stream.Context().Done():
			logger.Info("gRPC 流上下文已关闭", zap.Error(stream.Context().Err()))
			return stream.Context().Err()
		case <-a.ctx.Done():
			logger.Info("Agent 上下文已关闭")
			return a.ctx.Err()
		}
	}
}

func (a *Agent) SendRuleOperationalStatus(ruleID int64, status, detail string) {
	logger := zap.L().With(zap.Int64("规则ID", ruleID))
	msg := &proto.ClientToServerMessage{
		Payload: &proto.ClientToServerMessage_RuleStatusUpdate{
			RuleStatusUpdate: &proto.RuleOperationalStatusUpdate{
				RuleId: ruleID,
				Status: status,
				Detail: detail,
			},
		},
	}
	select {
	case a.ruleStatusUpdateChan <- msg:
		logger.Info("已发送规则状态更新", zap.String("状态", status), zap.String("详情", detail))
	case <-time.After(time.Second):
		logger.Warn("发送规则状态更新失败：channel 已满或阻塞")
	case <-a.ctx.Done():
		logger.Info("Agent 上下文已关闭，不再发送规则状态更新")
	}
}

func (a *Agent) handleRuleUpdate(rules []*proto.Rule) {
	logger := zap.L().With(zap.String("组件", "规则更新"))
	for _, rule := range rules {
		ruleLogger := logger.With(zap.Int64("规则ID", rule.RuleId), zap.String("类型", rule.Type))
		if oldFw, ok := a.forwarderManager.Remove(rule.RuleId); ok {
			oldFw.cancel()
			if oldFw.healthCheckCancel != nil {
				oldFw.healthCheckCancel()
			}
			if oldFw.Listener != nil {
				oldFw.Listener.Close()
			}
			if oldFw.PacketConn != nil {
				oldFw.PacketConn.Close()
			}
			if oldFw.udpReplyJobs != nil {
				close(oldFw.udpReplyJobs)
				oldFw.udpWg.Wait()
			}
			a.SendRuleOperationalStatus(rule.RuleId, "inactive", "规则已被后端停止或删除")
		}
		if rule.Action == proto.Rule_DELETE {
			a.trafficManager.Unregister(rule.RuleId)
			ruleLogger.Info("规则已删除")
			continue
		}
		switch rule.Type {
		case "direct":
			a.startDirectForwarder(rule, ruleLogger)
		case "tunnel":
			a.startTunnelForwarder(rule, ruleLogger)
		}
	}
}

func (a *Agent) startDirectForwarder(rule *proto.Rule, logger *zap.Logger) {
	logger.Info("正在启动直接转发器...")
	var listener net.Listener
	var packetConn net.PacketConn
	var err error
	listenAddr := fmt.Sprintf(":%d", rule.ListenPort)
	if rule.Protocol == "udp" {
		packetConn, err = net.ListenPacket("udp", listenAddr)
	} else {
		listener, err = net.Listen("tcp", listenAddr)
	}
	if err != nil {
		logger.Error("启动监听失败", zap.Error(err))
		a.SendRuleOperationalStatus(rule.RuleId, "error", fmt.Sprintf("监听端口 %d 失败: %v", rule.ListenPort, err))
		return
	}
	a.SendRuleOperationalStatus(rule.RuleId, "listening", fmt.Sprintf("%s 监听器已在端口 %d 激活", strings.ToUpper(rule.Protocol), rule.ListenPort))

	fwCtx, fwCancel := context.WithCancel(a.ctx)
	fw := &Forwarder{
		Rule:              rule,
		Listener:          listener,
		PacketConn:        packetConn,
		cancel:            fwCancel,
		targetActiveConns: &sync.Map{},
	}

	if rule.TargetLoadBalancingStrategy == "weighted_round_robin" {
		fw.initOrResetWRRState()
	}

	if rule.HealthCheckEnabled {
		fw.healthStatus = NewTargetHealthStatus(rule.RemoteAddresses)
		a.startHealthChecker(fw)
	}

	if rule.SpeedLimitUpMbps > 0 {
		fw.uploadLimiter = rate.NewLimiter(rate.Limit(rule.SpeedLimitUpMbps*1024*1024/8), int(rule.SpeedLimitUpMbps*1024*1024/8))
		logger.Info("上传限速已启用", zap.Float32("速率 (Mbps)", rule.SpeedLimitUpMbps))
	}
	if rule.SpeedLimitDownMbps > 0 {
		fw.downloadLimiter = rate.NewLimiter(rate.Limit(rule.SpeedLimitDownMbps*1024*1024/8), int(rule.SpeedLimitDownMbps*1024*1024/8))
		logger.Info("下载限速已启用", zap.Float32("速率 (Mbps)", rule.SpeedLimitDownMbps))
	}

	a.forwarderManager.Add(fw)
	a.trafficManager.Register(rule.RuleId)

	if rule.Protocol == "udp" {
		fw.udpReplyJobs = make(chan udpReplyJob, 128)
		numWorkers := runtime.NumCPU()
		if numWorkers == 0 {
			numWorkers = 2
		}
		fw.udpWg.Add(numWorkers)
		for i := 0; i < numWorkers; i++ {
			go a.udpReplyWorker(fw)
		}
		go a.handleUDPDirectForward(fwCtx, fw)
	} else {
		go a.handleTCPDirectForward(fwCtx, fw)
	}
}

func (a *Agent) startTunnelForwarder(rule *proto.Rule, logger *zap.Logger) {
	logger.Info("正在启动隧道转发器...")
	listener, err := net.Listen("tcp", fmt.Sprintf(":%d", rule.ListenPort))
	if err != nil {
		logger.Error("启动隧道监听失败", zap.Error(err))
		a.SendRuleOperationalStatus(rule.RuleId, "error", fmt.Sprintf("监听隧道端口 %d 失败: %v", rule.ListenPort, err))
		return
	}

	var finalListener net.Listener
	switch rule.Protocol {
	case "tls", "wss":
		finalListener = tls.NewListener(listener, a.tunnelTLSConfig)
	case "tcp", "udp", "ws":
		finalListener = listener
	default:
		logger.Error("不支持的隧道入口协议", zap.String("协议", rule.Protocol))
		listener.Close()
		return
	}

	fwCtx, fwCancel := context.WithCancel(a.ctx)
	fw := &Forwarder{Rule: rule, Listener: finalListener, cancel: fwCancel}

	if rule.SpeedLimitUpMbps > 0 {
		fw.uploadLimiter = rate.NewLimiter(rate.Limit(rule.SpeedLimitUpMbps*1024*1024/8), int(rule.SpeedLimitUpMbps*1024*1024/8))
		logger.Info("隧道上传限速已启用", zap.Float32("速率 (Mbps)", rule.SpeedLimitUpMbps))
	}
	if rule.SpeedLimitDownMbps > 0 {
		fw.downloadLimiter = rate.NewLimiter(rate.Limit(rule.SpeedLimitDownMbps*1024*1024/8), int(rule.SpeedLimitDownMbps*1024*1024/8))
		logger.Info("隧道下载限速已启用", zap.Float32("速率 (Mbps)", rule.SpeedLimitDownMbps))
	}

	a.forwarderManager.Add(fw)
	a.trafficManager.Register(rule.RuleId)
	a.SendRuleOperationalStatus(rule.RuleId, "connecting", fmt.Sprintf("隧道入口监听器已在端口 %d 激活", rule.ListenPort))
	go a.handleTunnelConnections(fwCtx, fw)
}

func (a *Agent) handleTCPDirectForward(ctx context.Context, fw *Forwarder) {
	if fw == nil || fw.Rule == nil {
		zap.L().Error("handleTCPDirectForward 被调用时 forwarder 或 rule 为空")
		return
	}
	logger := zap.L().With(zap.Int64("规则ID", fw.Rule.RuleId))
	defer fw.Listener.Close()
	go func() { <-ctx.Done(); fw.Listener.Close(); logger.Info("TCP 监听器已关闭") }()
	for {
		sourceConn, err := fw.Listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				logger.Info("TCP 监听器已正常关闭")
				a.SendRuleOperationalStatus(fw.Rule.RuleId, "inactive", "TCP 监听器已关闭")
				return
			}
			logger.Error("接受 TCP 连接失败", zap.Error(err))
			time.Sleep(time.Second)
			continue
		}
		go a.handleTCPConnection(sourceConn, fw)
	}
}

func (a *Agent) handleTCPConnection(source net.Conn, fw *Forwarder) {
	logger := zap.L().With(zap.Int64("规则ID", fw.Rule.RuleId))
	defer source.Close()

	clientIP, _, err := net.SplitHostPort(source.RemoteAddr().String())
	if err != nil {
		clientIP = source.RemoteAddr().String()
	}

	targetAddrs, err := a.selectTargetAddresses(fw.Rule, clientIP)
	if err != nil {
		logger.Error("选择目标地址失败", zap.Error(err), zap.String("客户端IP", clientIP))
		a.SendRuleOperationalStatus(fw.Rule.RuleId, "error", fmt.Sprintf("选择目标失败: %v", err))
		return
	}

	var destConn net.Conn
	for _, addr := range targetAddrs {
		destConn, err = net.DialTimeout("tcp", addr, 5*time.Second)
		if err == nil {
			break
		}
		logger.Warn("连接目标失败", zap.String("目标地址", addr), zap.Error(err))
	}
	if destConn == nil {
		logger.Error("无法连接到任何一个目标地址")
		a.SendRuleOperationalStatus(fw.Rule.RuleId, "error", "无法连接到任何目标")
		return
	}
	a.pipeConnections(source, destConn, fw)
}

func (a *Agent) selectTargetAddresses(rule *proto.Rule, clientIP string) ([]string, error) {
	fw, ok := a.forwarderManager.Get(int64(rule.RuleId))
	if !ok {
		return a.applyLoadBalancing(rule.TargetLoadBalancingStrategy, rule.RemoteAddresses, rule.RuleId, clientIP)
	}

	if !fw.Rule.HealthCheckEnabled || fw.healthStatus == nil {
		return a.applyLoadBalancing(fw.Rule.TargetLoadBalancingStrategy, fw.Rule.RemoteAddresses, fw.Rule.RuleId, clientIP)
	}

	fw.healthStatus.mu.RLock()
	healthyTargets := make([]string, 0, len(fw.Rule.RemoteAddresses))
	for _, addr := range fw.Rule.RemoteAddresses {
		if isHealthy, exists := fw.healthStatus.status[addr]; exists && isHealthy {
			healthyTargets = append(healthyTargets, addr)
		}
	}
	fw.healthStatus.mu.RUnlock()

	if len(healthyTargets) == 0 {
		zap.L().Warn("没有可用的健康目标，将尝试使用所有目标作为后备", zap.Int64("规则ID", rule.RuleId))
		a.SendRuleOperationalStatus(rule.RuleId, "error", "所有目标均不健康，服务可能中断")
		return a.applyLoadBalancing(fw.Rule.TargetLoadBalancingStrategy, fw.Rule.RemoteAddresses, fw.Rule.RuleId, clientIP)
	}

	return a.applyLoadBalancing(fw.Rule.TargetLoadBalancingStrategy, healthyTargets, fw.Rule.RuleId, clientIP)
}

func (a *Agent) applyLoadBalancing(strategy string, targets []string, ruleId int64, clientIP string) ([]string, error) {
	if len(targets) == 0 {
		return nil, errors.New("没有提供可用于负载均衡的地址")
	}

	resultTargets := make([]string, len(targets))
	copy(resultTargets, targets)

	fw, fwOk := a.forwarderManager.Get(ruleId)

	switch strategy {
	case "round_robin":
		val, _ := a.roundRobinCounters.LoadOrStore(ruleId, new(atomic.Uint64))
		counter := val.(*atomic.Uint64)
		startIndex := counter.Add(1) - 1
		for i := 0; i < len(resultTargets); i++ {
			resultTargets[i] = targets[(int(startIndex)+i)%len(targets)]
		}
		return resultTargets, nil

	case "random":
		mrand.Shuffle(len(resultTargets), func(i, j int) {
			resultTargets[i], resultTargets[j] = resultTargets[j], resultTargets[i]
		})
		return resultTargets, nil

	case "weighted_round_robin":
		if !fwOk {
			return a.applyLoadBalancing("random", targets, ruleId, clientIP)
		}
		healthySet := make(map[string]struct{}, len(targets))
		for _, addr := range targets {
			healthySet[addr] = struct{}{}
		}
		bestTarget, err := fw.selectNextWeightedTarget(healthySet)
		if err != nil {
			return a.applyLoadBalancing("random", targets, ruleId, clientIP)
		}
		bestIdx := -1
		for i, addr := range resultTargets {
			if addr == bestTarget {
				bestIdx = i
				break
			}
		}
		if bestIdx != -1 {
			resultTargets[0], resultTargets[bestIdx] = resultTargets[bestIdx], resultTargets[0]
		}
		return resultTargets, nil

	case "least_connections":
		if !fwOk {
			return a.applyLoadBalancing("random", targets, ruleId, clientIP)
		}
		var minConns int32 = -1
		var bestTargets []string
		for _, addr := range targets {
			counter := fw.getTargetConnCounter(addr)
			currentConns := counter.Load()
			if minConns == -1 || currentConns < minConns {
				minConns = currentConns
				bestTargets = []string{addr}
			} else if currentConns == minConns {
				bestTargets = append(bestTargets, addr)
			}
		}
		if len(bestTargets) == 0 {
			return a.applyLoadBalancing("random", targets, ruleId, clientIP)
		}
		bestTarget := bestTargets[mrand.Intn(len(bestTargets))]
		bestIdx := -1
		for i, addr := range resultTargets {
			if addr == bestTarget {
				bestIdx = i
				break
			}
		}
		if bestIdx != -1 {
			resultTargets[0], resultTargets[bestIdx] = resultTargets[bestIdx], resultTargets[0]
		}
		return resultTargets, nil

	case "ip_hash":
		if clientIP == "" {
			return a.applyLoadBalancing("random", targets, ruleId, clientIP)
		}
		hash := fnv1a(clientIP)
		index := int(hash % uint32(len(targets)))
		bestTarget := targets[index]
		bestIdx := -1
		for i, addr := range resultTargets {
			if addr == bestTarget {
				bestIdx = i
				break
			}
		}
		if bestIdx != -1 {
			resultTargets[0], resultTargets[bestIdx] = resultTargets[bestIdx], resultTargets[0]
		}
		return resultTargets, nil

	default:
		return resultTargets, nil
	}
}

func (a *Agent) handleTunnelConnections(ctx context.Context, fw *Forwarder) {
	if fw == nil || fw.Rule == nil {
		zap.L().Error("handleTunnelConnections 被调用时 forwarder 或 rule 为空")
		return
	}
	logger := zap.L().With(zap.Int64("规则ID", fw.Rule.RuleId))
	defer fw.Listener.Close()
	go func() { <-ctx.Done(); fw.Listener.Close(); logger.Info("隧道监听器已关闭") }()
	for {
		sourceConn, err := fw.Listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				logger.Info("隧道监听器已正常关闭")
				a.SendRuleOperationalStatus(fw.Rule.RuleId, "inactive", "隧道监听器已关闭")
				return
			}
			logger.Error("接受隧道连接失败", zap.Error(err))
			time.Sleep(time.Second)
			continue
		}
		logger.Info("已接受隧道连接", zap.String("远端地址", sourceConn.RemoteAddr().String()))
		go a.handleTunnelConnection(sourceConn, fw)
	}
}

func (a *Agent) handleTunnelConnection(source net.Conn, fw *Forwarder) {
	logger := zap.L().With(zap.Int64("规则ID", fw.Rule.RuleId))
	defer source.Close()
	a.egressGroupsMu.RLock()
	serverList, ok := a.egressGroups[fw.Rule.GetTargetId()]
	a.egressGroupsMu.RUnlock()
	if !ok || len(serverList.GetServers()) == 0 {
		logger.Warn("未找到目标出口服务器", zap.Int64("目标ID", fw.Rule.GetTargetId()))
		a.SendRuleOperationalStatus(fw.Rule.RuleId, "error", "未找到在线的出口服务器")
		return
	}
	servers := serverList.GetServers()
	mrand.Shuffle(len(servers), func(i, j int) { servers[i], servers[j] = servers[j], servers[i] })
	var destConn net.Conn
	var connectedEgressAddr string

	for _, egressServer := range servers {
		egressAddr := net.JoinHostPort(egressServer.GetAddress(), fmt.Sprintf("%d", egressServer.GetTunnelListenPort()))
		tlsDialer := &tls.Dialer{Config: a.tunnelTLSConfig}
		var err error
		destConn, err = tlsDialer.DialContext(a.ctx, "tcp", egressAddr)
		if err == nil {
			logger.Info("已连接到出口节点", zap.String("出口地址", egressAddr))
			connectedEgressAddr = egressAddr
			break
		}
		logger.Warn("连接出口节点失败", zap.String("出口地址", egressAddr), zap.Error(err))
	}

	if destConn == nil {
		logger.Error("无法连接到任何一个出口节点")
		a.SendRuleOperationalStatus(fw.Rule.RuleId, "error", "无法连接到任何出口节点")
		return
	}
	a.SendRuleOperationalStatus(fw.Rule.RuleId, "active", fmt.Sprintf("隧道已建立，出口为 %s", connectedEgressAddr))
	metadata := TunnelMetadata{
		RemoteAddresses:             fw.Rule.GetRemoteAddresses(),
		TargetLoadBalancingStrategy: fw.Rule.GetTargetLoadBalancingStrategy(),
	}
	metadataBytes, err := json.Marshal(metadata)
	if err != nil {
		logger.Error("序列化隧道元数据失败", zap.Error(err))
		destConn.Close()
		a.SendRuleOperationalStatus(fw.Rule.RuleId, "error", fmt.Sprintf("序列化隧道元数据失败: %v", err))
		return
	}
	destConn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := destConn.Write(append(metadataBytes, '\n')); err != nil {
		logger.Error("发送隧道元数据失败", zap.Error(err))
		destConn.Close()
		a.SendRuleOperationalStatus(fw.Rule.RuleId, "error", fmt.Sprintf("发送隧道元数据失败: %v", err))
		return
	}
	destConn.SetWriteDeadline(time.Time{})
	a.pipeConnections(source, destConn, fw)
	logger.Info("隧道连接会话已结束")
}

func (a *Agent) pipeConnections(source, dest net.Conn, fw *Forwarder) {
	logger := zap.L().With(zap.Int64("规则ID", fw.Rule.RuleId))

	isLeastConns := fw.Rule.TargetLoadBalancingStrategy == "least_connections"
	if isLeastConns {
		targetAddr := dest.RemoteAddr().String()
		targetConnCounter := fw.getTargetConnCounter(targetAddr)
		targetConnCounter.Add(1)
		defer targetConnCounter.Add(-1)
	}

	if max := fw.Rule.MaxConns; max > 0 {
		if current := fw.activeConns.Add(1); current > max {
			fw.activeConns.Add(-1)
			source.Close()
			dest.Close()
			logger.Warn("超出最大连接数限制", zap.Int32("最大连接数", max))
			return
		}
	} else {
		fw.activeConns.Add(1)
	}
	defer fw.activeConns.Add(-1)

	defer source.Close()
	defer dest.Close()

	stats, _ := a.trafficManager.GetStats(fw.Rule.RuleId)
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		bufPtr := bufferPool.Get().(*[]byte)
		defer bufferPool.Put(bufPtr)
		var written int64
		if fw.uploadLimiter != nil {
			written, _ = limitedCopyBuffer(dest, source, fw.uploadLimiter, *bufPtr)
		} else {
			written, _ = io.CopyBuffer(dest, source, *bufPtr)
		}
		if stats != nil {
			stats.inbound.Add(written)
		}
	}()

	go func() {
		defer wg.Done()
		bufPtr := bufferPool.Get().(*[]byte)
		defer bufferPool.Put(bufPtr)
		var written int64
		if fw.downloadLimiter != nil {
			written, _ = limitedCopyBuffer(source, dest, fw.downloadLimiter, *bufPtr)
		} else {
			written, _ = io.CopyBuffer(source, dest, *bufPtr)
		}
		if stats != nil {
			stats.outbound.Add(written)
		}
	}()
	wg.Wait()
}

func (a *Agent) handleUDPDirectForward(ctx context.Context, fw *Forwarder) {
	if fw == nil || fw.Rule == nil {
		zap.L().Error("handleUDPDirectForward 被调用时 forwarder 或 rule 为空")
		return
	}
	logger := zap.L().With(zap.Int64("规则ID", fw.Rule.RuleId))
	defer fw.PacketConn.Close()

	go func() {
		<-ctx.Done()
		fw.PacketConn.Close()
		if fw.udpReplyJobs != nil {
			close(fw.udpReplyJobs)
		}
		logger.Info("UDP 监听器已关闭")
	}()

	shards := make([]*udpSessionShard, udpSessionShards)
	for i := 0; i < len(shards); i++ {
		shards[i] = &udpSessionShard{
			sessions: make(map[string]*udpSession),
		}
	}

	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				now := time.Now()
				for i := 0; i < len(shards); i++ {
					shard := shards[i]
					shard.Lock()
					for key, session := range shard.sessions {
						if lastActivity, ok := session.lastActivity.Load().(time.Time); ok {
							if now.Sub(lastActivity) > 60*time.Second {
								session.remoteConn.Close()
								delete(shard.sessions, key)
							}
						}
					}
					shard.Unlock()
				}
			}
		}
	}()

	bufPtr := bufferPool.Get().(*[]byte)
	defer bufferPool.Put(bufPtr)
	buf := *bufPtr

	for {
		n, clientAddr, err := fw.PacketConn.ReadFrom(buf)
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				logger.Info("UDP 监听器已正常关闭")
				a.SendRuleOperationalStatus(fw.Rule.RuleId, "inactive", "UDP 监听器已关闭")
				return
			}
			logger.Error("从 UDP 读取失败", zap.Error(err))
			time.Sleep(time.Second)
			continue
		}

		clientAddrStr := clientAddr.String()

		shardIndex := fnv1a(clientAddrStr) % udpSessionShards
		shard := shards[shardIndex]

		shard.Lock()
		session, ok := shard.sessions[clientAddrStr]
		shard.Unlock()

		if !ok {
			clientIP, _, err := net.SplitHostPort(clientAddr.String())
			if err != nil {
				clientIP = clientAddr.String()
			}
			
			targetAddrs, err := a.selectTargetAddresses(fw.Rule, clientIP)
			if err != nil {
				logger.Error("为 UDP 选择目标地址失败", zap.Error(err))
				continue
			}
			remoteConn, err := net.Dial("udp", targetAddrs[0])
			if err != nil {
				logger.Warn("连接 UDP 目标失败", zap.String("目标地址", targetAddrs[0]), zap.Error(err))
				continue
			}

			newSession := &udpSession{remoteConn: remoteConn}
			newSession.lastActivity.Store(time.Now())

			shard.Lock()
			if existingSession, found := shard.sessions[clientAddrStr]; found {
				session = existingSession
				remoteConn.Close()
			} else {
				// 【核心修正】修正这里的拼写错误
				shard.sessions[clientAddrStr] = newSession
				session = newSession

				fw.activeConns.Add(1)
				stats, _ := a.trafficManager.GetStats(fw.Rule.RuleId)
				job := udpReplyJob{
					remoteConn: remoteConn,
					clientAddr: clientAddr,
					stats:      stats,
					onClose: func() {
						shard.Lock()
						delete(shard.sessions, clientAddrStr)
						shard.Unlock()
						fw.activeConns.Add(-1)
					},
				}
				select {
				case fw.udpReplyJobs <- job:
				default:
					logger.Warn("UDP worker 池已满，丢弃会话")
					remoteConn.Close()
					delete(shard.sessions, clientAddrStr)
					fw.activeConns.Add(-1)
				}
			}
			shard.Unlock()
		}

		session.lastActivity.Store(time.Now())
		if _, err := session.remoteConn.Write(buf[:n]); err != nil {
			logger.Warn("向 UDP 远端写入失败", zap.Error(err))
			continue
		}
		if stats, ok := a.trafficManager.GetStats(fw.Rule.RuleId); ok {
			stats.inbound.Add(int64(n))
		}
	}
}

func (a *Agent) udpReplyWorker(fw *Forwarder) {
	logger := zap.L().With(zap.Int64("rule_id", fw.Rule.RuleId))
	defer fw.udpWg.Done()
	respBufPtr := bufferPool.Get().(*[]byte)
	defer bufferPool.Put(respBufPtr)
	respBuf := *respBufPtr
	for job := range fw.udpReplyJobs {
		for {
			job.remoteConn.SetReadDeadline(time.Now().Add(30 * time.Second))
			m, err := job.remoteConn.Read(respBuf)
			if err != nil {
				logger.Warn("UDP read error", zap.Error(err))
				break
			}
			_, err = fw.PacketConn.WriteTo(respBuf[:m], job.clientAddr)
			if err != nil {
				logger.Warn("UDP write error", zap.Error(err))
				break
			}
			if job.stats != nil {
				job.stats.outbound.Add(int64(m))
			}
		}
		job.remoteConn.Close()
		if job.onClose != nil {
			job.onClose()
		}
	}
}

func initLogger(level, format string) {
	var zapConfig zap.Config
	if format == "console" {
		zapConfig = zap.NewDevelopmentConfig()
		zapConfig.EncoderConfig.EncodeLevel = zapcore.CapitalColorLevelEncoder
	} else {
		zapConfig = zap.NewProductionConfig()
	}
	logLevel := zap.NewAtomicLevel()
	logLevel.UnmarshalText([]byte(level))
	zapConfig.Level = logLevel
	logger, _ := zapConfig.Build()
	zap.ReplaceGlobals(logger)
}

func main() {
	mrand.New(mrand.NewSource(time.Now().UnixNano()))
	configPath := flag.String("config", "config.json", "Config file")
	secretKey := flag.String("key", "", "Secret key")
	serverAddr := flag.String("server", "", "Server address")
	reportInterval := flag.Int("interval", 0, "Report interval")
	logLevel := flag.String("loglevel", "info", "Log level")
	logFormat := flag.String("logformat", "json", "Log format")
	flag.Parse()
	cfg, err := loadAndValidateConfig(*configPath, *secretKey, *serverAddr, *reportInterval, *logLevel, *logFormat)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to load config: %v\n", err)
		os.Exit(1)
	}
	initLogger(cfg.LogLevel, cfg.LogFormat)
	defer zap.L().Sync()
	agent, err := NewAgent(cfg)
	if err != nil {
		zap.L().Error("Failed to create agent", zap.Error(err))
		os.Exit(1)
	}
	if err := agent.Run(); err != nil {
		zap.L().Error("Agent run failed", zap.Error(err))
		os.Exit(1)
	}
}

func loadAndValidateConfig(path, key, server string, interval int, level, format string) (*Config, error) {
	cfg := &Config{
		ReportInterval: 3,
		LogLevel:       "info",
		LogFormat:      "json",
		CACertPath:     "certs/ca.pem", // 设置 CA 证书的默认路径
	}
	if file, err := os.Open(path); err == nil {
		defer file.Close()
		json.NewDecoder(file).Decode(cfg)
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("failed to open config file %s: %w", path, err)
	}

	// 命令行参数覆盖配置文件
	if key != "" { cfg.SecretKey = key }
	if server != "" { cfg.BackendAddress = server }
	if interval > 0 { cfg.ReportInterval = interval }
	if level != "" { cfg.LogLevel = level }
	if format != "" { cfg.LogFormat = format }

	// 最终验证
	if cfg.SecretKey == "" { return nil, errors.New("secret_key is required") }
	if cfg.BackendAddress == "" { return nil, errors.New("backend_address is required") }

	return cfg, nil
}

func (a *Agent) sendReportPayloads(stream proto.NodeService_SyncClient) error {
	logger := zap.L().With(zap.String("component", "send"))
	if err := stream.Send(&proto.ClientToServerMessage{Payload: &proto.ClientToServerMessage_Heartbeat{Heartbeat: &proto.Heartbeat{}}}); err != nil {
		logger.Error("发送心跳失败", zap.Error(err))
		return err
	}
	statusReport := a.collectStatusReport()
	if err := stream.Send(&proto.ClientToServerMessage{Payload: &proto.ClientToServerMessage_StatusReport{StatusReport: statusReport}}); err != nil {
		logger.Error("发送状态报告失败", zap.Error(err))
		return err
	}
	trafficStats := a.trafficManager.GetAndResetAll()
	if len(trafficStats) > 0 {
		if err := stream.Send(&proto.ClientToServerMessage{Payload: &proto.ClientToServerMessage_TrafficReport{TrafficReport: &proto.TrafficReport{Stats: trafficStats}}}); err != nil {
			logger.Error("发送流量报告失败", zap.Error(err))
			return err
		}
	}
	return nil
}


func limitedCopyBuffer(dst io.Writer, src io.Reader, limiter *rate.Limiter, buf []byte) (written int64, err error) {
	if buf == nil {
		buf = make([]byte, 32*1024)
	}
	for {
		nr, er := src.Read(buf)
		if nr > 0 {
			if err := limiter.WaitN(context.Background(), nr); err != nil {
				return written, err
			}
			nw, ew := dst.Write(buf[0:nr])
			if nw > 0 {
				written += int64(nw)
			}
			if ew != nil {
				err = ew
				break
			}
			if nr != nw {
				err = io.ErrShortWrite
				break
			}
		}
		if er != nil {
			if er != io.EOF {
				err = er
			}
			break
		}
	}
	return written, err
}

func collectSystemInfo() *proto.SystemInfo {
	cpuInfo, _ := cpu.Info()
	memInfo, _ := mem.VirtualMemory()
	diskPath := "/"
	if runtime.GOOS == "windows" {
		diskPath = "C:"
	}
	diskInfo, _ := disk.Usage(diskPath)
	var cpuModel string
	var cpuCores uint32
	if len(cpuInfo) > 0 {
		cpuModel = cpuInfo[0].ModelName
		cpuCores = uint32(cpuInfo[0].Cores)
	}
	return &proto.SystemInfo{
		Os: runtime.GOOS, Arch: runtime.GOARCH, CpuModel: cpuModel, CpuCores: cpuCores,
		TotalMemory: memInfo.Total, TotalDisk: diskInfo.Total,
	}
}

func (a *Agent) collectStatusReport() *proto.StatusReport {
	cpuUsage, memUsage, diskUsage := collectSystemStats()
	uptime := getSystemUptime()
	totalTxBps, totalRxBps, totalTxBytes, totalRxBytes := a.collectNetworkStats()
	latencyTests := collectLatencyTests() // 这个函数现在返回 []*proto.LatencyStat
	totalConns := a.forwarderManager.TotalConnections()

	return &proto.StatusReport{
		CpuUsagePercent:  cpuUsage,
		MemUsagePercent:  memUsage,
		DiskUsagePercent: diskUsage,
		UptimeSeconds:    uptime,
		TotalTxBps:       totalTxBps,
		TotalRxBps:       totalRxBps,
		TotalTxBytes:     totalTxBytes,
		TotalRxBytes:     totalRxBytes,
		LatencyTests:     latencyTests,
		TotalConns:       totalConns,
	}
}

func collectSystemStats() (cpuUsage, memUsage, diskUsage float64) {
	cpuP, _ := cpu.Percent(time.Second, false)
	if len(cpuP) > 0 {
		cpuUsage = cpuP[0]
	}
	vm, _ := mem.VirtualMemory()
	memUsage = vm.UsedPercent
	diskPath := "/"
	if runtime.GOOS == "windows" {
		diskPath = "C:"
	}
	du, _ := disk.Usage(diskPath)
	diskUsage = du.UsedPercent
	return
}

func getSystemUptime() int64 {
	uptime, _ := host.Uptime()
	return int64(uptime)
}

func (a *Agent) collectNetworkStats() (totalTxBps, totalRxBps float64, totalTxBytes, totalRxBytes int64) {
	a.netStatsLock.Lock()
	defer a.netStatsLock.Unlock()

	ioCounters, err := psnet.IOCounters(true)
	if err != nil {
		zap.L().Warn("Failed to collect network stats", zap.Error(err))
		return 0, 0, 0, 0
	}

	currentTime := time.Now()
	var currentTotalBytesSent, currentTotalBytesRecv uint64
	for _, c := range ioCounters {
		// 增加对 veth 接口的过滤，这在 Docker 环境中很常见
		if strings.HasPrefix(c.Name, "lo") || strings.Contains(c.Name, "docker") || strings.HasPrefix(c.Name, "veth") {
			continue
		}
		currentTotalBytesSent += c.BytesSent
		currentTotalBytesRecv += c.BytesRecv
	}

	// 只有在有上一次记录时才计算速率
	if !a.lastNetStatTime.IsZero() {
		var lastTotalBytesSent, lastTotalBytesRecv uint64
		for _, c := range a.lastNetStats {
			if strings.HasPrefix(c.Name, "lo") || strings.Contains(c.Name, "docker") || strings.HasPrefix(c.Name, "veth") {
				continue
			}
			lastTotalBytesSent += c.BytesSent
			lastTotalBytesRecv += c.BytesRecv
		}
		duration := currentTime.Sub(a.lastNetStatTime).Seconds()
		if duration > 0 {
			// 防止 uint 下溢
			if currentTotalBytesSent >= lastTotalBytesSent {
				totalTxBps = float64(currentTotalBytesSent-lastTotalBytesSent) / duration
			}
			if currentTotalBytesRecv >= lastTotalBytesRecv {
				totalRxBps = float64(currentTotalBytesRecv-lastTotalBytesRecv) / duration
			}
		}
	}

	// 更新记录以供下次计算
	a.lastNetStats = ioCounters
	a.lastNetStatTime = currentTime

	return totalTxBps, totalRxBps, int64(currentTotalBytesSent), int64(currentTotalBytesRecv)
}

func collectLatencyTests() []*proto.LatencyStat {
	targets := []latencyTarget{
		{Name: "移动", Addr: "120.233.18.250:80"},
		{Name: "联通", Addr: "157.148.58.29:80"},
		{Name: "电信", Addr: "183.47.126.35:80"},
	}
	results := make([]*proto.LatencyStat, len(targets))
	var wg sync.WaitGroup
	for i, target := range targets {
		wg.Add(1)
		go func(index int, t latencyTarget) {
			defer wg.Done()
			latency, err := performTCPing(t.Addr)
			if err != nil {
				latency = -1.0 // 使用负数表示超时或错误
			}
			results[index] = &proto.LatencyStat{
				Target:    t.Name,
				LatencyMs: latency,
			}
		}(i, target)
	}
	wg.Wait()
	return results
}

func performTCPing(address string) (float64, error) {
	start := time.Now()
	conn, err := net.DialTimeout("tcp", address, 2*time.Second)
	if err != nil {
		return 0, err
	}
	conn.Close()
	return float64(time.Since(start).Nanoseconds()) / 1e6, nil
}

func performPing(ipAddress string) *proto.PingResult {
	logger := zap.L().With(zap.String("target", ipAddress))
	
	// --- 初始化时，使用新的 target_address 字段 ---
	result := &proto.PingResult{
		TargetAddress: ipAddress,
		Success:       false,
	}

	var cmd *exec.Cmd
	// 定义一个临时的变量来存储解析出的丢包率
	var parsedPacketLoss float64

	// 根据操作系统构建 ping 命令
	if runtime.GOOS == "windows" {
		cmd = exec.Command("ping", "-n", "4", "-w", "1000", ipAddress)
	} else { // Linux/macOS
		cmd = exec.Command("ping", "-c", "4", "-i", "0.2", "-W", "2", ipAddress)
	}

	// 执行命令并处理输出编码
	outputBytes, err := cmd.CombinedOutput()
	var outputStr string
	if runtime.GOOS == "windows" {
		reader := transform.NewReader(bytes.NewReader(outputBytes), simplifiedchinese.GBK.NewDecoder())
		utf8Bytes, readErr := io.ReadAll(reader)
		if readErr != nil {
			logger.Warn("Failed to convert ping output from GBK to UTF-8, using raw output.", zap.Error(readErr))
			outputStr = string(outputBytes)
		} else {
			outputStr = string(utf8Bytes)
		}
	} else {
		outputStr = string(outputBytes)
	}
	result.RawOutput = outputStr

	if err != nil {
		result.ErrorMessage = fmt.Sprintf("Ping command failed: %v", err)
		logger.Warn("Ping command execution failed", zap.Error(err))
	}

	// --- 使用 proto 中已有的 packet_loss_percent 正则表达式 ---

	// 解析 Linux/macOS 格式
	avgRegexLinux := regexp.MustCompile(`rtt min/avg/max/mdev = [\d.]+/([\d.]+)/`)
	if match := avgRegexLinux.FindStringSubmatch(outputStr); len(match) > 1 {
		result.Success = true
		if avg, err := strconv.ParseFloat(match[1], 64); err == nil {
			result.AvgLatencyMs = avg
		}
	}
	pktRegexLinux := regexp.MustCompile(`(\d+) packets transmitted, (\d+) received, ([\d.]+)% packet loss`)
	if match := pktRegexLinux.FindStringSubmatch(outputStr); len(match) > 3 {
		if loss, err := strconv.ParseFloat(match[3], 64); err == nil {
			parsedPacketLoss = loss
		}
		// (可选) 填充 packets_transmitted 和 packets_received
		if val, err := strconv.ParseInt(match[1], 10, 32); err == nil { result.PacketsTransmitted = int32(val) }
		if val, err := strconv.ParseInt(match[2], 10, 32); err == nil { result.PacketsReceived = int32(val) }
	}

	// 解析 Windows 格式
	avgRegexWindows := regexp.MustCompile(`(?:Average|平均) = (\d+)ms`)
	if match := avgRegexWindows.FindStringSubmatch(outputStr); len(match) > 1 {
		result.Success = true
		if avg, err := strconv.ParseFloat(match[1], 64); err == nil {
			result.AvgLatencyMs = avg
		}
	}
	pktRegexWindows := regexp.MustCompile(`(?:Lost|丢失) = \d+ \((\d+)%\w*\)`)
	if match := pktRegexWindows.FindStringSubmatch(outputStr); len(match) > 1 {
		if loss, err := strconv.ParseFloat(match[1], 64); err == nil {
			parsedPacketLoss = loss
		}
	}
	// (可选) 解析 Windows 的收发包数
	pktSentReceivedWindows := regexp.MustCompile(`(?:Sent|已发送) = (\d+), (?:Received|已接收) = (\d+)`)
	if match := pktSentReceivedWindows.FindStringSubmatch(outputStr); len(match) > 2 {
		if val, err := strconv.ParseInt(match[1], 10, 32); err == nil { result.PacketsTransmitted = int32(val) }
		if val, err := strconv.ParseInt(match[2], 10, 32); err == nil { result.PacketsReceived = int32(val) }
	}
	
	// --- 将解析出的丢包率赋值给 proto 中的 packet_loss_percent 字段 ---
	result.PacketLossPercent = parsedPacketLoss

	if !result.Success && result.ErrorMessage == "" {
		result.ErrorMessage = "Failed to parse ping output or all packets lost."
	}

	logger.Info("Ping completed", 
		zap.Bool("success", result.Success), 
		zap.Float64("avg_latency_ms", result.AvgLatencyMs),
		zap.Float64("packet_loss_percent", result.PacketLossPercent),
	)
	
	return result
}


func min(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

type TunnelMetadata struct {
	RemoteAddresses             []string `json:"remote_addresses"`
	TargetLoadBalancingStrategy string   `json:"target_load_balancing_strategy"`
}

func (a *Agent) startTunnelServer() {
	logger := zap.L().With(zap.String("component", "tunnel_server"))
	if a.tunnelListenPort == 0 {
		logger.Info("未配置隧道监听端口，隧道服务器将不会启动")
		return
	}
	listenAddr := fmt.Sprintf("0.0.0.0:%d", a.tunnelListenPort)
	listener, err := tls.Listen("tcp", listenAddr, a.tunnelTLSConfig)
	if err != nil {
		logger.Error("启动隧道服务器监听器失败", zap.Int("端口", a.tunnelListenPort), zap.Error(err))
		return
	}
	defer listener.Close()
	logger.Info("隧道服务器已启动", zap.String("地址", listenAddr))
	go func() {
		<-a.ctx.Done()
		listener.Close()
		logger.Info("隧道服务器监听器已关闭")
	}()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				logger.Info("隧道服务器监听器已优雅关闭")
				return
			}
			logger.Warn("接受隧道连接失败", zap.Error(err))
			continue
		}
		logger.Info("接受隧道连接", zap.String("远程地址", conn.RemoteAddr().String()))
		go a.handleIncomingTunnel(conn)
	}
}


func (a *Agent) handleIncomingTunnel(tunnelConn net.Conn) {
	logger := zap.L().With(zap.String("组件", "隧道出口"))
	defer tunnelConn.Close()
	tunnelConn.SetReadDeadline(time.Now().Add(10 * time.Second))
	reader := bufio.NewReader(tunnelConn)
	metadataBytes, err := reader.ReadBytes('\n')
	if err != nil {
		logger.Error("读取隧道元数据失败", zap.Error(err))
		return
	}
	tunnelConn.SetReadDeadline(time.Time{})
	var metadata TunnelMetadata
	if err := json.Unmarshal(metadataBytes, &metadata); err != nil {
		logger.Error("解析隧道元数据失败", zap.Error(err))
		return
	}
	logger.Info("收到隧道请求", zap.Strings("目标列表", metadata.RemoteAddresses))
	fakeRule := &proto.Rule{
		RemoteAddresses:             metadata.RemoteAddresses,
		TargetLoadBalancingStrategy: metadata.TargetLoadBalancingStrategy,
	}

	// 为 clientIP 参数传递一个空字符串
	targetAddrs, err := a.selectTargetAddresses(fakeRule, "")
	if err != nil {
		logger.Error("选择最终目标失败", zap.Error(err))
		return
	}
	
	var finalDestConn net.Conn
	for _, addr := range targetAddrs {
		finalDestConn, err = net.DialTimeout("tcp", addr, 5*time.Second)
		if err == nil {
			logger.Info("已连接到最终目标", zap.String("地址", addr))
			break
		}
		logger.Warn("连接最终目标失败", zap.String("地址", addr), zap.Error(err))
	}
	if finalDestConn == nil {
		logger.Error("无法连接到任何一个最终目标", zap.Strings("目标列表", targetAddrs))
		return
	}
	pipeRaw(tunnelConn, finalDestConn)
}

func pipeRaw(conn1, conn2 net.Conn) {
	defer conn1.Close()
	defer conn2.Close()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		bufPtr := bufferPool.Get().(*[]byte)
		defer bufferPool.Put(bufPtr)
		io.CopyBuffer(conn2, conn1, *bufPtr)
	}()
	go func() {
		defer wg.Done()
		bufPtr := bufferPool.Get().(*[]byte)
		defer bufferPool.Put(bufPtr)
		io.CopyBuffer(conn1, conn2, *bufPtr)
	}()
	wg.Wait()
}

// 计算两个整数的最大公约数 (GCD - Greatest Common Divisor)
func gcd(a, b int32) int32 {
	for b != 0 {
		a, b = b, a%b
	}
	return a
}

// 根据规则的目标和权重，初始化或重置 WRRState
func (fw *Forwarder) initOrResetWRRState() {
	fw.wrrStateMu.Lock()
	defer fw.wrrStateMu.Unlock()

	targets := fw.Rule.GetRemoteAddresses()
	weights := fw.Rule.GetTargetWeights()

	if len(targets) == 0 {
		fw.wrrState = nil
		return
	}

	wrrTargets := make([]WRRTarget, len(targets))
	var totalWeight, maxWeight, gcdVal int32
	
	for i, addr := range targets {
		weight := int32(1) // 默认权重为 1
		if w, ok := weights[addr]; ok {
			weight = w
		}
		wrrTargets[i] = WRRTarget{Address: addr, Weight: weight, EffectiveWeight: weight}
		
		totalWeight += weight
		if weight > maxWeight {
			maxWeight = weight
		}
		if i == 0 {
			gcdVal = weight
		} else {
			gcdVal = gcd(gcdVal, weight)
		}
	}
	
	fw.wrrState = &WRRState{
		Targets:       wrrTargets,
		TotalWeight:   totalWeight,
		maxWeight:     maxWeight,
		gcd:           gcdVal,
		currentIndex:  -1,
		currentWeight: 0,
	}
}

// 平滑加权轮询的核心选择算法
func (fw *Forwarder) selectNextWeightedTarget(healthyTargets map[string]struct{}) (string, error) {
	fw.wrrStateMu.Lock()
	defer fw.wrrStateMu.Unlock()

	state := fw.wrrState
	if state == nil || len(state.Targets) == 0 || state.maxWeight == 0 {
		return "", errors.New("WRR state not ready or no targets with positive weight")
	}

	for i := 0; i < len(state.Targets)*2; i++ { // 增加循环次数以确保在健康目标稀疏时也能找到
		state.currentIndex = (state.currentIndex + 1) % len(state.Targets)
		if state.currentIndex == 0 {
			state.currentWeight = state.currentWeight - state.gcd
			if state.currentWeight <= 0 {
				state.currentWeight = state.maxWeight
			}
		}

		currentTarget := &state.Targets[state.currentIndex]
		
		if _, isHealthy := healthyTargets[currentTarget.Address]; isHealthy {
			if currentTarget.Weight >= state.currentWeight {
				return currentTarget.Address, nil
			}
		}
	}
	
	// 如果循环后仍未找到（极小概率事件），则随机返回一个健康的目标作为降级
	for addr := range healthyTargets {
		return addr, nil
	}

	return "", errors.New("no healthy targets available for weighted selection")
}

// 为最少连接数策略获取或创建连接数计数器
func (fw *Forwarder) getTargetConnCounter(addr string) *atomic.Int32 {
	counter, _ := fw.targetActiveConns.LoadOrStore(addr, new(atomic.Int32))
	return counter.(*atomic.Int32)
}

// setupTunnelMTLS 是 mTLS 设置的总入口
func setupTunnelMTLS(config *Config) (*tls.Config, error) {
	// 1. 获取私有 CA 证书
	caCertPool, err := fetchCA(config)
	if err != nil {
		return nil, fmt.Errorf("获取私有CA失败: %w", err)
	}

	// 2. 生成我们自己的私钥
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("生成私钥失败: %w", err)
	}

	// 3. 创建证书签名请求 (CSR)
	csrBytes, err := createCSR(privateKey)
	if err != nil {
		return nil, fmt.Errorf("创建CSR失败: %w", err)
	}

	// 4. 从后端获取签发的证书
	certPEM, err := fetchSignedCert(config, csrBytes)
	if err != nil {
		return nil, fmt.Errorf("从后端获取签名证书失败: %w", err)
	}

	// 5. 将我们的私钥转换为 PEM 格式
	privateKeyPEM, err := privateKeyToPEM(privateKey)
	if err != nil {
		return nil, fmt.Errorf("将私钥转换为PEM格式失败: %w", err)
	}

	// 6. 使用我们获取到的证书和私钥创建 tls.Certificate
	deviceCert, err := tls.X509KeyPair(certPEM, privateKeyPEM)
	if err != nil {
		return nil, fmt.Errorf("加载设备密钥对失败: %w", err)
	}

	// 7. 创建最终的 mTLS 配置
	return &tls.Config{
		Certificates: []tls.Certificate{deviceCert},
		ClientCAs:    caCertPool,
		RootCAs:      caCertPool,
		ClientAuth:   tls.NoClientCert,
	}, nil
}

// fetchCA 从后端获取 CA 公共证书
func fetchCA(config *Config) (*x509.CertPool, error) {
	zap.L().Info("正在从后端获取私有CA证书...")

	// 创建一个只信任我们专属 CA 文件的 CertPool
	caCert, err := os.ReadFile(config.CACertPath)
	if err != nil {
		return nil, fmt.Errorf("从'%s'读取CA证书失败: %w", config.CACertPath, err)
	}
	rootCAs := x509.NewCertPool()
	if !rootCAs.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("从'%s'添加CA证书到池失败", config.CACertPath)
	}

	apiHost := extractApiHost(config.BackendAddress)

	// 使用这个专属的 CA 池来创建一个安全的 http.Client
	tr := &http.Transport{
		TLSClientConfig: &tls.Config{
			ServerName: apiHost,
			RootCAs:    rootCAs,
		},
	}
	client := &http.Client{Transport: tr, Timeout: 15 * time.Second}

	url := fmt.Sprintf("https://%s/api/v1/tunnel/ca", apiHost)

	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("后端返回非200状态码: %s, 响应体: %s", resp.Status, string(body))
	}

	caPEM, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	mTLSCertPool := x509.NewCertPool()
	if !mTLSCertPool.AppendCertsFromPEM(caPEM) {
		return nil, errors.New("添加获取的mTLS CA证书到池失败")
	}
	zap.L().Info("成功获取并加载私有CA")
	return mTLSCertPool, nil
}

// createCSR 创建证书签名请求
func createCSR(privateKey *ecdsa.PrivateKey) ([]byte, error) {
	template := &x509.CertificateRequest{
		Subject:            pkix.Name{CommonName: "hermes.agent"},
		SignatureAlgorithm: x509.ECDSAWithSHA256,
	}
	return x509.CreateCertificateRequest(rand.Reader, template, privateKey)
}

// fetchSignedCert 提交 CSR 并从后端获取签发的证书
func fetchSignedCert(config *Config, csrBytes []byte) ([]byte, error) {
	zap.L().Info("正在向后端请求签名证书...")
	csrPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: csrBytes})

	caCert, err := os.ReadFile(config.CACertPath)
	if err != nil {
		return nil, fmt.Errorf("从'%s'读取CA证书失败: %w", config.CACertPath, err)
	}
	rootCAs := x509.NewCertPool()
	if !rootCAs.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("从'%s'添加CA证书到池失败", config.CACertPath)
	}

	apiHost := extractApiHost(config.BackendAddress)

	tr := &http.Transport{
		TLSClientConfig: &tls.Config{
			ServerName: apiHost,
			RootCAs:    rootCAs,
		},
	}
	client := &http.Client{Transport: tr, Timeout: 15 * time.Second}

	url := fmt.Sprintf("https://%s/api/v1/tunnel/sign", apiHost)

	req, err := http.NewRequest("POST", url, bytes.NewReader(csrPEM))
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Secret-Key", config.SecretKey)
	req.Header.Set("Content-Type", "application/x-pem-file")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("后端返回非200状态码: %s, 响应体: %s", resp.Status, string(body))
	}
	
	certPEM, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	zap.L().Info("成功获取签名证书")
	return certPEM, nil
}


func extractApiHost(grpcAddress string) string {
    host, _, err := net.SplitHostPort(grpcAddress)
    if err != nil {
        return grpcAddress
    }
    return host 
}

// privateKeyToPEM 将 ecdsa.PrivateKey 转换为 PEM 格式
func privateKeyToPEM(privateKey *ecdsa.PrivateKey) ([]byte, error) {
	keyBytes, err := x509.MarshalECPrivateKey(privateKey)
	if err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes}), nil
}
