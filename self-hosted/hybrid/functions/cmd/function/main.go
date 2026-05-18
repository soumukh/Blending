package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"strings"
	"time"
)

type functionRequest struct {
	Method  string         `json:"method"`
	Payload map[string]any `json:"payload"`
}

type money struct {
	CurrencyCode string `json:"currencyCode"`
	Units        string `json:"units"`
	Nanos        int32  `json:"nanos"`
}

var currencyRates = map[string]float64{
	"USD": 1.00,
	"EUR": 0.92,
	"JPY": 155.0,
	"CAD": 1.37,
	"GBP": 0.79,
	"TRY": 32.0,
	"PHP": 57.0,
	"MXN": 17.0,
}

func main() {
	healthcheck := flag.Bool("healthcheck", false, "run a local health check")
	flag.Parse()
	if *healthcheck {
		return
	}

	service := strings.TrimSpace(os.Getenv("SERVICE"))
	if service == "" {
		log.Fatal("SERVICE must be set")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, map[string]string{"status": "ok", "service": service})
			return
		}

		var req functionRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if req.Payload == nil {
			req.Payload = map[string]any{}
		}

		resp, err := dispatch(service, req.Method, req.Payload)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(w, resp)
	})

	log.Printf("starting %s function on :8082", service)
	if err := http.ListenAndServe(":8082", mux); err != nil {
		log.Fatal(err)
	}
}

func dispatch(service, method string, payload map[string]any) (any, error) {
	switch service {
	case "email":
		return map[string]any{}, nil
	case "currency":
		return handleCurrency(method, payload)
	case "shipping":
		return handleShipping(method, payload)
	case "ad":
		return handleAd(payload), nil
	default:
		return nil, fmt.Errorf("unknown service %q", service)
	}
}

func handleCurrency(method string, payload map[string]any) (any, error) {
	if method == "GetSupportedCurrencies" || method == "" && len(payload) == 0 {
		codes := make([]string, 0, len(currencyRates))
		for code := range currencyRates {
			codes = append(codes, code)
		}
		return map[string]any{"currencyCodes": codes}, nil
	}

	fromMap, _ := payload["from"].(map[string]any)
	if fromMap == nil {
		fromMap, _ = payload["from_money"].(map[string]any)
	}
	from := parseMoney(fromMap)
	toCode := stringValue(payload, "toCode", "to_code")
	if toCode == "" {
		toCode = "USD"
	}

	amount := moneyToFloat(from)
	fromRate := rateOrUSD(from.CurrencyCode)
	toRate := rateOrUSD(toCode)
	converted := amount / fromRate * toRate
	return moneyFromFloat(strings.ToUpper(toCode), converted), nil
}

func handleShipping(method string, payload map[string]any) (any, error) {
	switch method {
	case "ShipOrder":
		return map[string]any{
			"trackingId": fmt.Sprintf("mtp-%d", time.Now().UnixNano()),
		}, nil
	default:
		itemCount := 0
		if items, ok := payload["items"].([]any); ok {
			itemCount = len(items)
		}
		cost := 8.99 + float64(itemCount)*0.75
		return map[string]any{"costUsd": moneyFromFloat("USD", cost)}, nil
	}
}

func handleAd(payload map[string]any) any {
	keys := []string{}
	if raw, ok := payload["contextKeys"].([]any); ok {
		for _, item := range raw {
			keys = append(keys, strings.ToLower(fmt.Sprint(item)))
		}
	}
	text := "Browse our featured cloud-native gifts"
	for _, key := range keys {
		if strings.Contains(key, "clothing") || strings.Contains(key, "shirt") {
			text = "Fresh styles for your next deployment"
			break
		}
		if strings.Contains(key, "home") || strings.Contains(key, "decor") {
			text = "Upgrade your workspace with something useful"
			break
		}
	}
	return map[string]any{
		"ads": []map[string]string{{
			"redirectUrl": "/product/OLJCESPC7Z",
			"text":        text,
		}},
	}
}

func writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}

func parseMoney(values map[string]any) money {
	if values == nil {
		values = map[string]any{}
	}
	return money{
		CurrencyCode: strings.ToUpper(defaultString(stringValue(values, "currencyCode", "currency_code"), "USD")),
		Units:        defaultString(stringValue(values, "units"), "0"),
		Nanos:        int32(numberValue(values, "nanos")),
	}
}

func moneyToFloat(value money) float64 {
	units := numberFromString(value.Units)
	return units + float64(value.Nanos)/1_000_000_000
}

func moneyFromFloat(code string, amount float64) money {
	units, frac := math.Modf(amount)
	nanos := int32(math.Round(frac * 1_000_000_000))
	if nanos >= 1_000_000_000 {
		units++
		nanos -= 1_000_000_000
	}
	return money{
		CurrencyCode: strings.ToUpper(code),
		Units:        fmt.Sprintf("%.0f", units),
		Nanos:        nanos,
	}
}

func rateOrUSD(code string) float64 {
	rate, ok := currencyRates[strings.ToUpper(code)]
	if !ok || rate == 0 {
		return 1
	}
	return rate
}

func stringValue(values map[string]any, keys ...string) string {
	for _, key := range keys {
		if raw, ok := values[key]; ok {
			switch typed := raw.(type) {
			case string:
				return typed
			case json.Number:
				return typed.String()
			default:
				return fmt.Sprint(typed)
			}
		}
	}
	return ""
}

func numberValue(values map[string]any, key string) float64 {
	raw, ok := values[key]
	if !ok {
		return 0
	}
	switch typed := raw.(type) {
	case float64:
		return typed
	case json.Number:
		value, _ := typed.Float64()
		return value
	case string:
		return numberFromString(typed)
	default:
		return 0
	}
}

func numberFromString(value string) float64 {
	var out float64
	_, _ = fmt.Sscanf(value, "%f", &out)
	return out
}

func defaultString(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
