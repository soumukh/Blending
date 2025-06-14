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
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	// "time"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/frontend/genproto"

	"github.com/pkg/errors"
)

const (
	avoidNoopCurrencyConversionRPC = false
)

func (fe *frontendServer) getCurrencies(ctx context.Context) ([]string, error) {
	// currs, err := pb.NewCurrencyServiceClient(fe.currencySvcConn).
	// 	GetSupportedCurrencies(ctx, &pb.Empty{})
	// if err != nil {
	// 	return nil, err
	// }
	// var out []string
	// for _, c := range currs.CurrencyCodes {
	// 	if _, ok := whitelistedCurrencies[c]; ok {
	// 		out = append(out, c)
	// 	}
	// }
	// return out, nil
	//reduce the call to gcf-currency to reduce the overhead / if want we can still put an action in the gcf later to make it dynamic.
	allCurrencies := []string{
		"EUR", "USD", "JPY", "BGN", "CZK", "DKK", "GBP", "HUF", "PLN", "RON",
		"SEK", "CHF", "ISK", "NOK", "HRK", "RUB", "TRY", "AUD", "BRL", "CAD",
		"CNY", "HKD", "IDR", "ILS", "INR", "KRW", "MXN", "MYR", "NZD", "PHP", //these codes are taken from currency_conversion.json to remain updated with allowed currencies.
		"SGD", "THB", "ZAR",
	}
	var out []string
	for _, c := range allCurrencies {
		if _, ok := whitelistedCurrencies[c]; ok {
			out = append(out, c)
		}
	}
	return out, nil

}

func (fe *frontendServer) getProducts(ctx context.Context) ([]*pb.Product, error) {
	resp, err := pb.NewProductCatalogServiceClient(fe.productCatalogSvcConn).
		ListProducts(ctx, &pb.Empty{})
	return resp.GetProducts(), err
}

func (fe *frontendServer) getProduct(ctx context.Context, id string) (*pb.Product, error) {
	resp, err := pb.NewProductCatalogServiceClient(fe.productCatalogSvcConn).
		GetProduct(ctx, &pb.GetProductRequest{Id: id})
	return resp, err
}

func (fe *frontendServer) getCart(ctx context.Context, userID string) ([]*pb.CartItem, error) {
	resp, err := pb.NewCartServiceClient(fe.cartSvcConn).GetCart(ctx, &pb.GetCartRequest{UserId: userID})
	return resp.GetItems(), err
}

func (fe *frontendServer) emptyCart(ctx context.Context, userID string) error {
	_, err := pb.NewCartServiceClient(fe.cartSvcConn).EmptyCart(ctx, &pb.EmptyCartRequest{UserId: userID})
	return err
}

func (fe *frontendServer) insertCart(ctx context.Context, userID, productID string, quantity int32) error {
	_, err := pb.NewCartServiceClient(fe.cartSvcConn).AddItem(ctx, &pb.AddItemRequest{
		UserId: userID,
		Item: &pb.CartItem{
			ProductId: productID,
			Quantity:  quantity},
	})
	return err
}

func (fe *frontendServer) convertCurrency(ctx context.Context, money *pb.Money, currency string) (*pb.Money, error) {
	if avoidNoopCurrencyConversionRPC && money.GetCurrencyCode() == currency {
		return money, nil
	}
	// return pb.NewCurrencyServiceClient(fe.currencySvcConn).
	// 	Convert(ctx, &pb.CurrencyConversionRequest{
	// 		From:   money,
	// 		ToCode: currency})

	gcfURL := "https://us-central1-cloudblend-435916.cloudfunctions.net/convertCurrency" // Replace with your GCF URL
	params := url.Values{}
	params.Add("from_currency_code", money.GetCurrencyCode())
	params.Add("from_units", fmt.Sprintf("%d", money.GetUnits()))
	params.Add("from_nanos", fmt.Sprintf("%d", money.GetNanos()))
	params.Add("to_code", currency)
	fullURL := gcfURL + "?" + params.Encode()

	req, err := http.NewRequestWithContext(ctx, "GET", fullURL, nil)
	if err != nil {
		return nil, errors.Wrap(err, "failed to create GCF request")
	}
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return nil, errors.Wrap(err, "failed to call GCF")
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, errors.Errorf("GCF returned %d: %s", resp.StatusCode, string(body))
	}

	var result struct {
		Units        int64  `json:"units"`
		Nanos        int32  `json:"nanos"`
		CurrencyCode string `json:"currency_code"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, errors.Wrap(err, "failed to parse GCF response")
	}

	if result.CurrencyCode != currency {
		return nil, errors.Errorf("unexpected currency code: got %s, want %s", result.CurrencyCode, currency)
	}

	return &pb.Money{
		CurrencyCode: result.CurrencyCode,
		Units:        result.Units,
		Nanos:        result.Nanos,
	}, nil
}

func (fe *frontendServer) getShippingQuote(ctx context.Context, items []*pb.CartItem, currency string) (*pb.Money, error) {
	// quote, err := pb.NewShippingServiceClient(fe.shippingSvcConn).GetQuote(ctx,
	// 	&pb.GetQuoteRequest{
	// 		Address: nil,
	// 		Items:   items})
	// if err != nil {
	// 	return nil, err
	// }
	// localized, err := fe.convertCurrency(ctx, quote.GetCostUsd(), currency)
	// return localized, errors.Wrap(err, "failed to convert currency for shipping cost")
	
//the getQuote function in the shipping service is not directly used ,it's handled by checkout service completely.
	
	gcfURL := "https://us-central1-cloudblend-435916.cloudfunctions.net/shipping/getQuote"
	req, err := http.NewRequestWithContext(ctx, "GET", gcfURL, nil)
	if err != nil {
		return nil, errors.Wrap(err, "failed to create GCF shipping quote request")
	}
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return nil, errors.Wrap(err, "failed to call GCF for shipping quote")
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, errors.Errorf("GCF shipping quote returned %d: %s", resp.StatusCode, string(body))
	}

	var shippingResp struct {
		CostUSD struct {
			CurrencyCode string `json:"currency_code"`
			Units        int64  `json:"units"`
			Nanos        int32  `json:"nanos"`
		} `json:"cost_usd"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&shippingResp); err != nil {
		return nil, errors.Wrap(err, "failed to parse GCF shipping quote response")
	}

	quote := &pb.Money{
		CurrencyCode: shippingResp.CostUSD.CurrencyCode,
		Units:        shippingResp.CostUSD.Units,
		Nanos:        shippingResp.CostUSD.Nanos,
	}
	localized, err := fe.convertCurrency(ctx, quote, currency)
	return localized, errors.Wrap(err, "failed to convert currency for shipping cost")

}

func (fe *frontendServer) getRecommendations(ctx context.Context, userID string, productIDs []string) ([]*pb.Product, error) {
	resp, err := pb.NewRecommendationServiceClient(fe.recommendationSvcConn).ListRecommendations(ctx,
		&pb.ListRecommendationsRequest{UserId: userID, ProductIds: productIDs})
	if err != nil {
		return nil, err
	}
	out := make([]*pb.Product, len(resp.GetProductIds()))
	for i, v := range resp.GetProductIds() {
		p, err := fe.getProduct(ctx, v)
		if err != nil {
			return nil, errors.Wrapf(err, "failed to get recommended product info (#%s)", v)
		}
		out[i] = p
	}
	if len(out) > 4 {
		out = out[:4] // take only first four to fit the UI
	}
	return out, err
}

func (fe *frontendServer) getAd(ctx context.Context, ctxKeys []string) ([]*pb.Ad, error) {
	// ctx, cancel := context.WithTimeout(ctx, time.Millisecond*100)
	// defer cancel()

	// resp, err := pb.NewAdServiceClient(fe.adSvcConn).GetAds(ctx, &pb.AdRequest{
	// 	ContextKeys: ctxKeys,
	// })
	// return resp.GetAds(), errors.Wrap(err, "failed to get ads")

	gcfURL := "https://us-central1-cloudblend-435916.cloudfunctions.net/getAds"
    params := url.Values{}
    if len(ctxKeys) > 0 {
        params.Add("context_keys", strings.Join(ctxKeys, ","))
    }
    fullURL := gcfURL + "?" + params.Encode()

    req, err := http.NewRequestWithContext(ctx, "GET", fullURL, nil)
    if err != nil {
        return nil, errors.Wrap(err, "failed to create GCF ad request")
    }
    client := &http.Client{}
    resp, err := client.Do(req)
    if err != nil {
        return nil, errors.Wrap(err, "failed to call GCF for ads")
    }
    defer resp.Body.Close()

    if resp.StatusCode != http.StatusOK {
        body, _ := io.ReadAll(resp.Body)
        return nil, errors.Errorf("GCF returned %d: %s", resp.StatusCode, string(body))
    }

    var result struct {
        Ads []struct {
            RedirectURL string `json:"redirect_url"`
            Text        string `json:"text"`
        } `json:"ads"`
    }
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, errors.Wrap(err, "failed to parse GCF ad response")
    }

    ads := make([]*pb.Ad, len(result.Ads))
    for i, ad := range result.Ads {
        ads[i] = &pb.Ad{
            RedirectUrl: ad.RedirectURL,
            Text:        ad.Text,
        }
    }
    return ads, nil
}
