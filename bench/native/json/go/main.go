package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
)

type Line struct {
	Sku   int64 `json:"sku"`
	Qty   int64 `json:"qty"`
	Price int64 `json:"price"`
}
type Audit struct {
	Revision int64 `json:"revision"`
}
type Order struct {
	Kind     string  `json:"kind"`
	ID       int64   `json:"id"`
	Customer int64   `json:"customerId"`
	Total    int64   `json:"total"`
	Placed   int64   `json:"placedAt"`
	Lines    []Line  `json:"lines"`
	Note     *string `json:"note"`
	Source   string  `json:"source"`
	Audit    Audit   `json:"audit"`
}

func argument(i, fallback int) int {
	if len(os.Args) <= i {
		return fallback
	}
	n, err := strconv.Atoi(os.Args[i])
	if err != nil {
		panic(err)
	}
	return n
}
func main() {
	n, rounds := argument(1, 10000), argument(2, 20)
	inputs := make([]string, n)
	for i := range inputs {
		note, source := "null", "Web"
		if i%2 != 0 {
			note, source = `"deliver"`, "Store"
		}
		inputs[i] = fmt.Sprintf(`{"kind":"order","id":%d,"customerId":%d,"total":2598,"placedAt":1700000000,"lines":[{"sku":42,"qty":2,"price":1299}],"note":%s,"source":"%s","audit":{"revision":1}}`, i+1, i%97, note, source)
	}
	mode := "roundtrip"
	if len(os.Args) > 3 {
		mode = os.Args[3]
	}
	orders := make([]Order, 0)
	if mode == "encode" {
		for _, text := range inputs {
			var o Order
			if err := json.Unmarshal([]byte(text), &o); err != nil {
				panic(err)
			}
			orders = append(orders, o)
		}
	}
	var sum int64
	for r := 0; r < rounds; r++ {
		if mode == "encode" {
			for _, o := range orders {
				out, err := json.Marshal(o)
				if err != nil {
					panic(err)
				}
				sum += int64(len(out)) + int64(out[len(out)-2])
			}
			continue
		}
		for _, text := range inputs {
			var o Order
			if err := json.Unmarshal([]byte(text), &o); err != nil {
				panic(err)
			}
			if mode == "decode" {
				note := int64(0)
				if o.Note != nil {
					note = int64(len(*o.Note))
				}
				source := int64(1)
				if o.Source == "Store" {
					source = 2
				}
				sum += o.ID + o.Customer + o.Total + o.Placed + o.Lines[0].Sku + o.Lines[0].Qty + o.Lines[0].Price + o.Audit.Revision + note + source
				continue
			}
			out, err := json.Marshal(o)
			if err != nil {
				panic(err)
			}
			if string(out) != text {
				panic("round trip differs")
			}
			sum += o.ID + o.Customer + o.Total + o.Lines[0].Qty + o.Audit.Revision + int64(len(out))
		}
	}
	fmt.Println(sum)
}
