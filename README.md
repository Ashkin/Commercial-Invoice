#International commercial invoice generator

I wrote this (in Rails) for the shipping department while I worked for Pololu Robotics, inc. to automate the creation of international invoices.  They are exceedingly easy to read, too.

> For an example, see:  [commercial_invoice_1J73433.pdf](https://github.com/Ashkin/Commercial-Invoice/blob/master/commercial_invoice_1J73433.pdf)

The generator creates a commercial invoice from a given salesorder, supporting combination items, discounts, coupons, exclusions, and multiple languages/character sets.  It gracefully handles all edge-cases, such as multiple linked invoices, and automatically adds sections (e.g. coupons) as needed.  The entire process takes a little over one second, even for very large salesorders.  I've also included its rigorous test suite.

I'm quite proud of it.