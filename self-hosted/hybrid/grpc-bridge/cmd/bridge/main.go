package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	pb "mtp-grpc-bridge/genproto"
)

type bridge struct {
	pb.UnimplementedEmailServiceServer
	pb.UnimplementedCurrencyServiceServer
	pb.UnimplementedShippingServiceServer
	pb.UnimplementedAdServiceServer

	service     string
	functionURL string
	client      *http.Client
}

var (
	httpDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "bridge_http_duration_seconds",
		Help:    "Duration of bridge calls to OpenFaaS functions.",
		Buckets: prometheus.DefBuckets,
	}, []string{"service", "method"})
	translationDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "bridge_translation_duration_seconds",
		Help:    "Duration of JSON/protobuf translation inside the bridge.",
		Buckets: prometheus.DefBuckets,
	}, []string{"service", "method"})
	invocations = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "bridge_invocations_total",
		Help: "Total bridge gRPC invocations.",
	}, []string{"service", "method", "status"})
)

func main() {
	service := strings.TrimSpace(os.Getenv("SERVICE"))
	if service == "" {
		log.Fatal("SERVICE must be set to email, currency, shipping, or ad")
	}

	functionURL := strings.TrimSpace(os.Getenv("FUNCTION_URL"))
	if functionURL == "" {
		functionURL = fmt.Sprintf("http://gateway.openfaas.svc.cluster.local:8080/function/%s", service)
	}

	port := servicePort(service)
	if port == "" {
		log.Fatalf("unsupported bridge service %q", service)
	}

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		log.Printf("metrics listening on :9091")
		if err := http.ListenAndServe(":9091", nil); err != nil {
			log.Printf("metrics server stopped: %v", err)
		}
	}()

	listener, err := net.Listen("tcp", ":"+port)
	if err != nil {
		log.Fatal(err)
	}

	server := grpc.NewServer()
	b := &bridge{
		service:     service,
		functionURL: functionURL,
		client:      &http.Client{Timeout: 55 * time.Second},
	}
	registerService(server, service, b)

	log.Printf("%s bridge listening on :%s and forwarding to %s", service, port, functionURL)
	if err := server.Serve(listener); err != nil {
		log.Fatal(err)
	}
}

func (b *bridge) SendOrderConfirmation(ctx context.Context, req *pb.SendOrderConfirmationRequest) (*pb.Empty, error) {
	resp := &pb.Empty{}
	return resp, b.invoke(ctx, "SendOrderConfirmation", req, resp)
}

func (b *bridge) GetSupportedCurrencies(ctx context.Context, req *pb.Empty) (*pb.GetSupportedCurrenciesResponse, error) {
	resp := &pb.GetSupportedCurrenciesResponse{}
	return resp, b.invoke(ctx, "GetSupportedCurrencies", req, resp)
}

func (b *bridge) Convert(ctx context.Context, req *pb.CurrencyConversionRequest) (*pb.Money, error) {
	resp := &pb.Money{}
	return resp, b.invoke(ctx, "Convert", req, resp)
}

func (b *bridge) GetQuote(ctx context.Context, req *pb.GetQuoteRequest) (*pb.GetQuoteResponse, error) {
	resp := &pb.GetQuoteResponse{}
	return resp, b.invoke(ctx, "GetQuote", req, resp)
}

func (b *bridge) ShipOrder(ctx context.Context, req *pb.ShipOrderRequest) (*pb.ShipOrderResponse, error) {
	resp := &pb.ShipOrderResponse{}
	return resp, b.invoke(ctx, "ShipOrder", req, resp)
}

func (b *bridge) GetAds(ctx context.Context, req *pb.AdRequest) (*pb.AdResponse, error) {
	resp := &pb.AdResponse{}
	return resp, b.invoke(ctx, "GetAds", req, resp)
}

func (b *bridge) invoke(ctx context.Context, method string, in proto.Message, out proto.Message) error {
	translateStart := time.Now()
	payload, err := (protojson.MarshalOptions{EmitUnpopulated: true}).Marshal(in)
	if err != nil {
		invocations.WithLabelValues(b.service, method, "marshal_error").Inc()
		return err
	}
	body, err := json.Marshal(map[string]any{
		"method":  method,
		"payload": json.RawMessage(payload),
	})
	if err != nil {
		invocations.WithLabelValues(b.service, method, "marshal_error").Inc()
		return err
	}
	translationDuration.WithLabelValues(b.service, method).Observe(time.Since(translateStart).Seconds())

	httpStart := time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, b.functionURL, bytes.NewReader(body))
	if err != nil {
		invocations.WithLabelValues(b.service, method, "request_error").Inc()
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := b.client.Do(req)
	httpDuration.WithLabelValues(b.service, method).Observe(time.Since(httpStart).Seconds())
	if err != nil {
		invocations.WithLabelValues(b.service, method, "http_error").Inc()
		return err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		invocations.WithLabelValues(b.service, method, "read_error").Inc()
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		invocations.WithLabelValues(b.service, method, "function_error").Inc()
		return fmt.Errorf("function returned %s: %s", resp.Status, strings.TrimSpace(string(respBody)))
	}

	translateStart = time.Now()
	if len(bytes.TrimSpace(respBody)) > 0 {
		if err := (protojson.UnmarshalOptions{DiscardUnknown: true}).Unmarshal(respBody, out); err != nil {
			invocations.WithLabelValues(b.service, method, "unmarshal_error").Inc()
			return fmt.Errorf("decode function response: %w: %s", err, strings.TrimSpace(string(respBody)))
		}
	}
	translationDuration.WithLabelValues(b.service, method).Observe(time.Since(translateStart).Seconds())
	invocations.WithLabelValues(b.service, method, "ok").Inc()
	return nil
}

func servicePort(service string) string {
	switch service {
	case "email":
		return "5000"
	case "currency":
		return "7000"
	case "shipping":
		return "50051"
	case "ad":
		return "9555"
	default:
		return ""
	}
}

func registerService(server *grpc.Server, service string, b *bridge) {
	switch service {
	case "email":
		pb.RegisterEmailServiceServer(server, b)
	case "currency":
		pb.RegisterCurrencyServiceServer(server, b)
	case "shipping":
		pb.RegisterShippingServiceServer(server, b)
	case "ad":
		pb.RegisterAdServiceServer(server, b)
	default:
		log.Fatalf("unsupported bridge service %q", service)
	}
}
