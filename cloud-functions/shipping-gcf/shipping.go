package shipping

import (
    "encoding/json"
    "fmt"
    "math"
    "math/rand"
    "time"
    "net/http"
)

// Quote represents a currency value.
type Quote struct {
    Dollars uint32
    Cents   uint32
}

// CreateQuoteFromFloat takes a price as a float and creates a Quote struct.
func CreateQuoteFromFloat(value float64) Quote {
    units, fraction := math.Modf(value)
    return Quote{
        Dollars: uint32(units),
        Cents:   uint32(math.Trunc(fraction * 100)),
    }
}

// Tracking ID generation
var seeded bool = false
var rng *rand.Rand

func CreateTrackingId(salt string) string {
    if !seeded {
		rng = rand.New(rand.NewSource(time.Now().UnixNano()))   
		seeded = true
    }
    return fmt.Sprintf("%c%c-%d%s-%d%s",
        getRandomLetterCode(),
        getRandomLetterCode(),
        len(salt),
        getRandomNumber(3),
        len(salt)/2,
        getRandomNumber(7),
    )
}

func getRandomLetterCode() uint32 {
    return 65 + uint32(rng.Intn(25))
}

func getRandomNumber(digits int) string {
    str := ""
    for i := 0; i < digits; i++ {
        str = fmt.Sprintf("%s%d", str, rng.Intn(10))
    }
    return str
}

// HTTP handler for GCF
func ShippingHandler(w http.ResponseWriter, r *http.Request) {
    switch r.URL.Path {
    case "/getQuote":
        // Fixed $8.99 quote (reuses CreateQuoteFromFloat)
        quote := CreateQuoteFromFloat(8.99)
        resp := struct {
            CostUSD struct {
                CurrencyCode string `json:"currency_code"`
                Units        int64  `json:"units"`
                Nanos        int32  `json:"nanos"`
            } `json:"cost_usd"`
        }{
            CostUSD: struct {
                CurrencyCode string `json:"currency_code"`
                Units        int64  `json:"units"`
                Nanos        int32  `json:"nanos"`
            }{
                CurrencyCode: "USD",
                Units:        int64(quote.Dollars),
                Nanos:        int32(quote.Cents * 10000000), // Cents to nanos
            },
        }
        w.Header().Set("Content-Type", "application/json")
        if err := json.NewEncoder(w).Encode(resp); err != nil {
            http.Error(w, fmt.Sprintf("Failed to encode response: %v", err), http.StatusInternalServerError)
            return
        }

    case "/shipOrder":
        var req struct {
            Address struct {
                StreetAddress string `json:"street_address"`
                City          string `json:"city"`
                State         string `json:"state"`
            } `json:"address"`
        }
        if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
            http.Error(w, fmt.Sprintf("Failed to decode request: %v", err), http.StatusBadRequest)
            return
        }
        baseAddress := fmt.Sprintf("%s, %s, %s", req.Address.StreetAddress, req.Address.City, req.Address.State)
        trackingID := CreateTrackingId(baseAddress)
        resp := struct {
            TrackingID string `json:"tracking_id"`
        }{TrackingID: trackingID}
        w.Header().Set("Content-Type", "application/json")
        if err := json.NewEncoder(w).Encode(resp); err != nil {
            http.Error(w, fmt.Sprintf("Failed to encode response: %v", err), http.StatusInternalServerError)
            return
        }

    default:
        http.Error(w, "Endpoint not found", http.StatusNotFound)
    }
}

// func main() {
//     http.HandleFunc("/", ShippingHandler)
// }