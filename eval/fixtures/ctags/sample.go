package payments

import "fmt"

type Refund struct {
	ID     string
	Amount int
}

func NewRefund(id string) *Refund {
	return &Refund{ID: id}
}

func (r *Refund) Process() error {
	fmt.Println("processing", r.ID)
	return nil
}
