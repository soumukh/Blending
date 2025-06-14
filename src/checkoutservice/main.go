// Copyright 2018 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"time"
	"net/http"
	"bytes"
	"encoding/json"
	"net/url"
	"io"


	"cloud.google.com/go/profiler"
	"github.com/google/uuid"
	"github.com/pkg/errors"
	"github.com/sirupsen/logrus"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/checkoutservice/genproto"
	money "github.com/GoogleCloudPlatform/microservices-demo/src/checkoutservice/money"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"

	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

const (
	listenPort  = "5050"
	usdCurrency = "USD"
)

var log *logrus.Logger

func init() {
	log = logrus.New()
	log.Level = logrus.DebugLevel
	log.Formatter = &logrus.JSONFormatter{
		FieldMap: logrus.FieldMap{
			logrus.FieldKeyTime:  "timestamp",
			logrus.FieldKeyLevel: "severity",
			logrus.FieldKeyMsg:   "message",
		},
		TimestampFormat: time.RFC3339Nano,
	}
	log.Out = os.Stdout
}

type checkoutService struct {
	pb.UnimplementedCheckoutServiceServer

	productCatalogSvcAddr string
	productCatalogSvcConn *grpc.ClientConn

	cartSvcAddr string
	cartSvcConn *grpc.ClientConn

	// currencySvcAddr string //going to be removed
	// currencySvcConn *grpc.ClientConn //going to be removed

	// shippingSvcAddr string
	// shippingSvcConn *grpc.ClientConn

// it is to be removed since we are gonna use http connection 
	// emailSvcAddr string
	// emailSvcConn *grpc.ClientConn

	paymentSvcAddr string
	paymentSvcConn *grpc.ClientConn
}

func main() {
	ctx := context.Background()
	if os.Getenv("ENABLE_TRACING") == "1" {
		log.Info("Tracing enabled.")
		initTracing()

	} else {
		log.Info("Tracing disabled.")
	}

	if os.Getenv("ENABLE_PROFILER") == "1" {
		log.Info("Profiling enabled.")
		go initProfiling("checkoutservice", "1.0.0")
	} else {
		log.Info("Profiling disabled.")
	}

	port := listenPort
	if os.Getenv("PORT") != "" {
		port = os.Getenv("PORT")
	}

	svc := new(checkoutService)
	// mustMapEnv(&svc.shippingSvcAddr, "SHIPPING_SERVICE_ADDR")
	mustMapEnv(&svc.productCatalogSvcAddr, "PRODUCT_CATALOG_SERVICE_ADDR")
	mustMapEnv(&svc.cartSvcAddr, "CART_SERVICE_ADDR")
	// mustMapEnv(&svc.currencySvcAddr, "CURRENCY_SERVICE_ADDR")  //going to be removed
	// mustMapEnv(&svc.emailSvcAddr, "EMAIL_SERVICE_ADDR") //this must be changed
	mustMapEnv(&svc.paymentSvcAddr, "PAYMENT_SERVICE_ADDR")

	// mustConnGRPC(ctx, &svc.shippingSvcConn, svc.shippingSvcAddr)
	mustConnGRPC(ctx, &svc.productCatalogSvcConn, svc.productCatalogSvcAddr)
	mustConnGRPC(ctx, &svc.cartSvcConn, svc.cartSvcAddr)
	// mustConnGRPC(ctx, &svc.currencySvcConn, svc.currencySvcAddr) //going to be removed
	// mustConnGRPC(ctx, &svc.emailSvcConn, svc.emailSvcAddr) //this must be changed
	mustConnGRPC(ctx, &svc.paymentSvcConn, svc.paymentSvcAddr)

	log.Infof("service config: %+v", svc)

	lis, err := net.Listen("tcp", fmt.Sprintf(":%s", port))
	if err != nil {
		log.Fatal(err)
	}

	var srv *grpc.Server

	// Propagate trace context always
	otel.SetTextMapPropagator(
		propagation.NewCompositeTextMapPropagator(
			propagation.TraceContext{}, propagation.Baggage{}))
	srv = grpc.NewServer(
		grpc.UnaryInterceptor(otelgrpc.UnaryServerInterceptor()),
		grpc.StreamInterceptor(otelgrpc.StreamServerInterceptor()),
	)

	pb.RegisterCheckoutServiceServer(srv, svc)
	healthpb.RegisterHealthServer(srv, svc)
	log.Infof("starting to listen on tcp: %q", lis.Addr().String())
	err = srv.Serve(lis)
	log.Fatal(err)
}

func initStats() {
	//TODO(arbrown) Implement OpenTelemetry stats
}

func initTracing() {
	var (
		collectorAddr string
		collectorConn *grpc.ClientConn
	)

	ctx := context.Background()
	ctx, cancel := context.WithTimeout(ctx, time.Second*3)
	defer cancel()

	mustMapEnv(&collectorAddr, "COLLECTOR_SERVICE_ADDR")
	mustConnGRPC(ctx, &collectorConn, collectorAddr)

	exporter, err := otlptracegrpc.New(
		ctx,
		otlptracegrpc.WithGRPCConn(collectorConn))
	if err != nil {
		log.Warnf("warn: Failed to create trace exporter: %v", err)
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithSampler(sdktrace.AlwaysSample()))
	otel.SetTracerProvider(tp)

}

func initProfiling(service, version string) {
	// TODO(ahmetb) this method is duplicated in other microservices using Go
	// since they are not sharing packages.
	for i := 1; i <= 3; i++ {
		if err := profiler.Start(profiler.Config{
			Service:        service,
			ServiceVersion: version,
			// ProjectID must be set if not running on GCP.
			// ProjectID: "my-project",
		}); err != nil {
			log.Warnf("failed to start profiler: %+v", err)
		} else {
			log.Info("started Stackdriver profiler")
			return
		}
		d := time.Second * 10 * time.Duration(i)
		log.Infof("sleeping %v to retry initializing Stackdriver profiler", d)
		time.Sleep(d)
	}
	log.Warn("could not initialize Stackdriver profiler after retrying, giving up")
}

func mustMapEnv(target *string, envKey string) {
	v := os.Getenv(envKey)
	if v == "" {
		panic(fmt.Sprintf("environment variable %q not set", envKey))
	}
	*target = v
}

func mustConnGRPC(ctx context.Context, conn **grpc.ClientConn, addr string) {
	var err error
	ctx, cancel := context.WithTimeout(ctx, time.Second*3)
	defer cancel()
	*conn, err = grpc.DialContext(ctx, addr,
		grpc.WithInsecure(),
		grpc.WithUnaryInterceptor(otelgrpc.UnaryClientInterceptor()),
		grpc.WithStreamInterceptor(otelgrpc.StreamClientInterceptor()))
	if err != nil {
		panic(errors.Wrapf(err, "grpc: failed to connect %s", addr))
	}
}

func (cs *checkoutService) Check(ctx context.Context, req *healthpb.HealthCheckRequest) (*healthpb.HealthCheckResponse, error) {
	return &healthpb.HealthCheckResponse{Status: healthpb.HealthCheckResponse_SERVING}, nil
}

func (cs *checkoutService) Watch(req *healthpb.HealthCheckRequest, ws healthpb.Health_WatchServer) error {
	return status.Errorf(codes.Unimplemented, "health check via Watch not implemented")
}

func (cs *checkoutService) PlaceOrder(ctx context.Context, req *pb.PlaceOrderRequest) (*pb.PlaceOrderResponse, error) {
	log.Infof("[PlaceOrder] user_id=%q user_currency=%q", req.UserId, req.UserCurrency)

	orderID, err := uuid.NewUUID()
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to generate order uuid")
	}

	prep, err := cs.prepareOrderItemsAndShippingQuoteFromCart(ctx, req.UserId, req.UserCurrency, req.Address)
	if err != nil {
		return nil, status.Errorf(codes.Internal, err.Error())
	}

	total := pb.Money{CurrencyCode: req.UserCurrency,
		Units: 0,
		Nanos: 0}
	total = money.Must(money.Sum(total, *prep.shippingCostLocalized))
	for _, it := range prep.orderItems {
		multPrice := money.MultiplySlow(*it.Cost, uint32(it.GetItem().GetQuantity()))
		total = money.Must(money.Sum(total, multPrice))
	}

	txID, err := cs.chargeCard(ctx, &total, req.CreditCard)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to charge card: %+v", err)
	}
	log.Infof("payment went through (transaction_id: %s)", txID)

	shippingTrackingID, err := cs.shipOrder(ctx, req.Address, prep.cartItems)
	if err != nil {
		return nil, status.Errorf(codes.Unavailable, "shipping error: %+v", err)
	}

	_ = cs.emptyUserCart(ctx, req.UserId)

	orderResult := &pb.OrderResult{
		OrderId:            orderID.String(),
		ShippingTrackingId: shippingTrackingID,
		ShippingCost:       prep.shippingCostLocalized,
		ShippingAddress:    req.Address,
		Items:              prep.orderItems,
	}

	if err := cs.sendOrderConfirmation(ctx, req.Email, orderResult); err != nil {
		log.Warnf("failed to send order confirmation to %q: %+v", req.Email, err)
	} else {
		log.Infof("order confirmation email sent to %q", req.Email)
	}
	resp := &pb.PlaceOrderResponse{Order: orderResult}
	return resp, nil
}

type orderPrep struct {
	orderItems            []*pb.OrderItem
	cartItems             []*pb.CartItem
	shippingCostLocalized *pb.Money
}

func (cs *checkoutService) prepareOrderItemsAndShippingQuoteFromCart(ctx context.Context, userID, userCurrency string, address *pb.Address) (orderPrep, error) {
	var out orderPrep
	cartItems, err := cs.getUserCart(ctx, userID)
	if err != nil {
		return out, fmt.Errorf("cart failure: %+v", err)
	}
	orderItems, err := cs.prepOrderItems(ctx, cartItems, userCurrency)
	if err != nil {
		return out, fmt.Errorf("failed to prepare order: %+v", err)
	}
	shippingUSD, err := cs.quoteShipping(ctx, address, cartItems)
	if err != nil {
		return out, fmt.Errorf("shipping quote failure: %+v", err)
	}
	shippingPrice, err := cs.convertCurrency(ctx, shippingUSD, userCurrency)
	if err != nil {
		return out, fmt.Errorf("failed to convert shipping cost to currency: %+v", err)
	}

	out.shippingCostLocalized = shippingPrice
	out.cartItems = cartItems
	out.orderItems = orderItems
	return out, nil
}

func (cs *checkoutService) quoteShipping(ctx context.Context, address *pb.Address, items []*pb.CartItem) (*pb.Money, error) {
	// shippingQuote, err := pb.NewShippingServiceClient(cs.shippingSvcConn).
	// 	GetQuote(ctx, &pb.GetQuoteRequest{
	// 		Address: address,
	// 		Items:   items})
	// if err != nil {
	// 	return nil, fmt.Errorf("failed to get shipping quote: %+v", err)
	// }
	// return shippingQuote.GetCostUsd(), nil

	gcfURL := "https://us-central1-cloudblend-435916.cloudfunctions.net/shipping/getQuote"
	req, err := http.NewRequestWithContext(ctx, "GET", gcfURL, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create GCF shipping quote request: %v", err)
	}
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to call GCF for shipping quote: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("GCF shipping quote returned %d: %s", resp.StatusCode, string(body))
	}

	var shippingResp struct {
		CostUSD struct {
			CurrencyCode string `json:"currency_code"`
			Units        int64  `json:"units"`
			Nanos        int32  `json:"nanos"`
		} `json:"cost_usd"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&shippingResp); err != nil {
		return nil, fmt.Errorf("failed to parse GCF shipping quote response: %v", err)
	}

	return &pb.Money{
		CurrencyCode: shippingResp.CostUSD.CurrencyCode,
		Units:        shippingResp.CostUSD.Units,
		Nanos:        shippingResp.CostUSD.Nanos,
	}, nil

}

func (cs *checkoutService) getUserCart(ctx context.Context, userID string) ([]*pb.CartItem, error) {
	cart, err := pb.NewCartServiceClient(cs.cartSvcConn).GetCart(ctx, &pb.GetCartRequest{UserId: userID})
	if err != nil {
		return nil, fmt.Errorf("failed to get user cart during checkout: %+v", err)
	}
	return cart.GetItems(), nil
}

func (cs *checkoutService) emptyUserCart(ctx context.Context, userID string) error {
	if _, err := pb.NewCartServiceClient(cs.cartSvcConn).EmptyCart(ctx, &pb.EmptyCartRequest{UserId: userID}); err != nil {
		return fmt.Errorf("failed to empty user cart during checkout: %+v", err)
	}
	return nil
}

func (cs *checkoutService) prepOrderItems(ctx context.Context, items []*pb.CartItem, userCurrency string) ([]*pb.OrderItem, error) {
	out := make([]*pb.OrderItem, len(items))
	cl := pb.NewProductCatalogServiceClient(cs.productCatalogSvcConn)

	for i, item := range items {
		product, err := cl.GetProduct(ctx, &pb.GetProductRequest{Id: item.GetProductId()})
		if err != nil {
			return nil, fmt.Errorf("failed to get product #%q", item.GetProductId())
		}
		price, err := cs.convertCurrency(ctx, product.GetPriceUsd(), userCurrency)
		if err != nil {
			return nil, fmt.Errorf("failed to convert price of %q to %s", item.GetProductId(), userCurrency)
		}
		out[i] = &pb.OrderItem{
			Item: item,
			Cost: price}
	}
	return out, nil
}

func (cs *checkoutService) convertCurrency(ctx context.Context, from *pb.Money, toCurrency string) (*pb.Money, error) {
	// result, err := pb.NewCurrencyServiceClient(cs.currencySvcConn).Convert(context.TODO(), &pb.CurrencyConversionRequest{
	// 	From:   from,
	// 	ToCode: toCurrency})
	// if err != nil {
	// 	return nil, fmt.Errorf("failed to convert currency: %+v", err)
	// }
	// return result, err

	return cs.convertCurrencyViaGCF(ctx, from, toCurrency)
}

func (cs *checkoutService) convertCurrencyViaGCF(ctx context.Context, from *pb.Money, toCurrency string) (*pb.Money, error) {
    // Replace with your GCF URL
    gcfURL := "https://us-central1-cloudblend-435916.cloudfunctions.net/convertCurrency"
    params := url.Values{}
    params.Add("from_currency_code", from.CurrencyCode)
    params.Add("from_units", fmt.Sprintf("%d", from.Units))
    params.Add("from_nanos", fmt.Sprintf("%d", from.Nanos))
    params.Add("to_code", toCurrency)
    fullURL := gcfURL + "?" + params.Encode()

    req, err := http.NewRequestWithContext(ctx, "GET", fullURL, nil)
    if err != nil {
        return nil, fmt.Errorf("failed to create GCF request: %v", err)
    }
    client := &http.Client{}
    resp, err := client.Do(req)
    if err != nil {
        return nil, fmt.Errorf("failed to call GCF: %v", err)
    }
    defer resp.Body.Close()

    if resp.StatusCode != http.StatusOK {
        body, _ := io.ReadAll(resp.Body) // Updated from ioutil.ReadAll
        return nil, fmt.Errorf("GCF returned %d: %s", resp.StatusCode, string(body))
    }

    var result struct {
        Units        int64  `json:"units"`
        Nanos        int32  `json:"nanos"`
        CurrencyCode string `json:"currency_code"`
    }
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, fmt.Errorf("failed to parse GCF response: %v", err)
    }

    if result.CurrencyCode != toCurrency {
        return nil, fmt.Errorf("unexpected currency code: got %s, want %s", result.CurrencyCode, toCurrency)
    }

    return &pb.Money{
        CurrencyCode: result.CurrencyCode,
        Units:        result.Units,
        Nanos:        result.Nanos,
    }, nil
}

func (cs *checkoutService) chargeCard(ctx context.Context, amount *pb.Money, paymentInfo *pb.CreditCardInfo) (string, error) {
	paymentResp, err := pb.NewPaymentServiceClient(cs.paymentSvcConn).Charge(ctx, &pb.ChargeRequest{
		Amount:     amount,
		CreditCard: paymentInfo})
	if err != nil {
		return "", fmt.Errorf("could not charge the card: %+v", err)
	}
	return paymentResp.GetTransactionId(), nil
}

func (cs *checkoutService) sendOrderConfirmation(ctx context.Context, email string, order *pb.OrderResult) error {
	// _, err := pb.NewEmailServiceClient(cs.emailSvcConn).SendOrderConfirmation(ctx, &pb.SendOrderConfirmationRequest{
	// 	Email: email,
	// 	Order: order})
	// return err

//new http call to gcf-email-service
orderData := map[string]interface{}{
	"email": email,
	"order": map[string]interface{}{
		"order_id":            order.OrderId,
		"shipping_tracking_id": order.ShippingTrackingId,
		"shipping_cost": map[string]interface{}{
			"units":         order.ShippingCost.Units,
			"nanos":         order.ShippingCost.Nanos,
			"currency_code": order.ShippingCost.CurrencyCode,
		},
		"shipping_address": map[string]interface{}{
			"street_address_1": order.ShippingAddress.StreetAddress,
			"street_address_2": "", // Optional, not in pb.Address; add if needed
			"city":             order.ShippingAddress.City,
			"country":          order.ShippingAddress.Country,
			"zip_code":         order.ShippingAddress.ZipCode,
		},
		"items": convertOrderItems(order.Items),
	},
}
jsonData, err := json.Marshal(orderData)
if err != nil {
	return fmt.Errorf("failed to marshal order data: %v", err)
}

gcfURL := "https://us-central1-cloudblend-435916.cloudfunctions.net/send_email" // Replace with your GCF URL
resp, err := http.Post(gcfURL, "application/json", bytes.NewBuffer(jsonData))
if err != nil {
	return fmt.Errorf("failed to call GCF: %v", err)
}
defer resp.Body.Close()

if resp.StatusCode != http.StatusOK {
	return fmt.Errorf("GCF returned non-OK status: %d", resp.StatusCode)
}
return nil
}

func convertOrderItems(items []*pb.OrderItem) []map[string]interface{} {
	var result []map[string]interface{}
	for _, item := range items {
		result = append(result, map[string]interface{}{
			"item": map[string]interface{}{
				"product_id": item.Item.ProductId,
				"quantity":   item.Item.Quantity,
			},
			"cost": map[string]interface{}{
				"units":         item.Cost.Units,
				"nanos":         item.Cost.Nanos,
				"currency_code": item.Cost.CurrencyCode,
			},
		})
	}
	return result
}

func (cs *checkoutService) shipOrder(ctx context.Context, address *pb.Address, items []*pb.CartItem) (string, error) {
	// resp, err := pb.NewShippingServiceClient(cs.shippingSvcConn).ShipOrder(ctx, &pb.ShipOrderRequest{
	// 	Address: address,
	// 	Items:   items})
	// if err != nil {
	// 	return "", fmt.Errorf("shipment failed: %+v", err)
	// }
	// return resp.GetTrackingId(), nil

	gcfURL := "https://us-central1-cloudblend-435916.cloudfunctions.net/shipping/shipOrder"
	shippingReq := struct {
		Address struct {
			StreetAddress string `json:"street_address"`
			City          string `json:"city"`
			State         string `json:"state"`
		} `json:"address"`
		
		}{
		Address: struct {
			StreetAddress string `json:"street_address"`
			City          string `json:"city"`
			State         string `json:"state"`
		}{
			StreetAddress: address.StreetAddress,
			City:          address.City,
			State:         address.State,
		},
	}
	jsonData, err := json.Marshal(shippingReq)
	if err != nil {
		return "", fmt.Errorf("failed to marshal shipping request: %v", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", gcfURL, bytes.NewBuffer(jsonData))
	if err != nil {
		return "", fmt.Errorf("failed to create GCF ship order request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to call GCF for ship order: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("GCF ship order returned %d: %s", resp.StatusCode, string(body))
	}

	var shipResp struct {
		TrackingID string `json:"tracking_id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&shipResp); err != nil {
		return "", fmt.Errorf("failed to parse GCF ship order response: %v", err)
	}

	return shipResp.TrackingID, nil
}
