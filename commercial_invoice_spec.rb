require 'spec_helper'

# Rigorous creation and testing of a sample invoice
describe CommercialInvoice do

  let(:invoice) do
    @salesorder = create(:salesorder, tax_id: "1234567890")

    @invoices = [create(:invoice, ship_time: nil, shipping_account_number: @shipping_account_number || ""),
                 create(:invoice)]

    same_package = create(:same_package)

    @invoices.each do |invoice|
      package = create(:package, :invoice => invoice, :same_package => same_package)

      shipping_to = create(:contact, :owner => invoice, :contact_type => "shipping")
      create(:name,          :owner => shipping_to)
      create(:address,       :owner => shipping_to)
      create(:phone,         :owner => shipping_to)
      create(:email_address, :owner => shipping_to)

      invoice_line_items    = []
      salesorder_line_items = []

      # Normal products
      5.times do
        product = create(:product, weight_ounces: 2)
        create(:assembly, product: product)
        salesorder_line_items << create(:salesorder_line_item, salesorder: @salesorder, product: product,
                                        unit_price: 5)
        invoice_line_items    << create(:invoice_line_item, salesorder_line_item: salesorder_line_items.last,
                                        invoice: invoice, quantity: 2)
        
        salesorder_line_items.last.update_attribute(:extended_weight_ounces,
          invoice_line_items.last.quantity * product.weight_ounces)
      end

      # exclude_from_customs product
      1.times do
        product = create(:product, exclude_from_customs: true)
        create(:assembly, product: product)
        salesorder_line_items << create(:salesorder_line_item, salesorder: @salesorder, product: product)
        invoice_line_items    << create(:invoice_line_item, invoice: invoice, quantity: 2,
                                        salesorder_line_item: salesorder_line_items.last)
 
        salesorder_line_items.last.update_attribute(:extended_weight_ounces,
          invoice_line_items.last.quantity * product.weight_ounces)
      end

      # Combination item
      product = create(:product, :combination, weight_ounces: 6)
      create(:assembly, product: product, schedule_b_code: "")
      salesorder_line_items << create(:salesorder_line_item, salesorder: @salesorder, product: product, unit_price: 5)
      invoice_line_items    << create(:invoice_line_item, invoice: invoice,
                                      salesorder_line_item: salesorder_line_items.last)
      2.times do
        included_product = create(:product)
        create(:product_combination, combination: product, product: included_product)
        create(:assembly, product: included_product)
      end

      # Discounts
      2.times do
        product = create(:product, :discount)
        create(:assembly, product: product, schedule_b_code: "")
        salesorder_line_items << create(:salesorder_line_item, salesorder: @salesorder, product: product,
                                        unit_price: -5, quantity_ordered: 1)
        invoice_line_items    << create(:invoice_line_item, invoice: invoice,
                                        salesorder_line_item: salesorder_line_items.last)
      end

      weight_ounces = salesorder_line_items.reject { |soli| soli.product.product_internal.exclude_from_customs }
                        .collect(&:extended_weight_ounces).inject(0, :+)
      package.update_attribute(:weight_ounces, weight_ounces)

      invoice.update_attribute     :shipping, 6
      @salesorder.update_attribute :shipping, 6

      subtotal = invoice_line_items.reject{ |item| item.salesorder_line_item.product.product_internal.exclude_from_customs }
                   .map(&:extended_price).inject(0, :+)
      @salesorder.update_attribute(:subtotal, subtotal)
      @salesorder.update_attribute(:total, @salesorder.subtotal + invoice.tax + invoice.shipping)

      invoice.update_attribute(:subtotal, @salesorder.subtotal)
      invoice.update_attribute(:total, @salesorder.total)
    end

    total_weight = @invoices.collect{|invoice| invoice.package[0].weight_ounces}.inject(0, :+)
    @invoices.each { |invoice| invoice.package[0].update_attribute(:weight_ounces, total_weight) }

    @invoices.first
  end

  let(:commercial_invoice) { CommercialInvoice.new(invoice) }

  specify ".new when passed an invalid object raises an exception" do
    expect { CommercialInvoice.new(:junk) }.to raise_error
  end

  describe "for a general example" do
    before(:all) do
      # Share the database rows and CommercialInvoice between the tests. This saves 13s on David's computer.
      commercial_invoice
    end

    it "loads the correct Invoice ID" do
      commercial_invoice.invoice.should == @invoices.collect(&:pkstring).join(", ")
    end

    it "loads the correct Salesorder ID" do
      # one salesorder across all linked invoices
      commercial_invoice.salesorder.should == invoice.salesorder.pkstring
    end

    ### Shipping/Tracking info --------------------

    it "should list the correct ship date, or today's date when missing" do
      # This invoice has a date specified.
      ci = CommercialInvoice.new(@invoices.last)
      ci.shipping_info["Ship Date"].should  eq  @invoices.last.ship_time.to_date.to_s

      # This invoice does not.
      commercial_invoice.shipping_info["Ship Date"].should  eq  Date.today.strftime("%Y-%m-%d")
    end

    it "should list the correct tracking number" do
      commercial_invoice.shipping_info["Tracking #"].should ==
        invoice.package[0].tracking_number
    end

    it "should list the correct shipping method" do
      commercial_invoice.shipping_info["Ship Method"].should eq invoice.shipping_service
    end

    it "should list the correct invoice numbers" do
      commercial_invoice.shipping_info["Invoices"].should eq @invoices.collect(&:pkstring).join(", ")
    end

    ### Address --------------------

    it "should display the contact and address correctly formatted" do
      commercial_invoice.addr_consignee.should eq ["Terra Ashley Bilderback",
                                                   "Beautiful Winds, inc",
                                                   "3365 Sunrise",
                                                   "Ariea, Sky  33655",
                                                   "Phone: +15558765309",
                                                   "example@pololu.com"]
    end

    it "should list a email address" do
      commercial_invoice.contact.email_address[0].email.should  eq  "example@pololu.com"
      invoice.shipping_contact.email_address[0].email.should    eq  "example@pololu.com"
    end

    it "should list a phone number" do
      commercial_invoice.contact.phone[0].string_number.should  eq  "+15558765309"
    end

    it "should have a matching Consignee and Importer address" do
      ci = commercial_invoice
      ci.addr_consignee.should  eq  ci.addr_importer
    end

    ### Lineitem table --------------------

    it "should load the correct number of products" do
      # 20 items + 1 for header.  This should not count the exclude_from_customs item.
      (commercial_invoice.items.length).should  eq  20+1
    end

    it "should use a header order matching the one used in this spec  (Sanity Check)" do
      header = commercial_invoice.items[0].collect { |i| i.downcase }
      header[1].should eq "quantity"
      header[2].should eq "item number"
      header[3].should eq "item description"
      header[4].should match /ext.+weight/i
      header[6].should match /ext.+price/i
      header[7].should eq "origin"
      header[8].should eq "hs code"
    end

    ### Table Summary (quantity, weight, etc) --------------------

    it "should have the correct total quantity" do
      commercial_invoice.total_quantity.should  eq  24
    end

    it "should have the correct weight" do
      commercial_invoice.total_weight.should  eq  52
    end

    it "should list the correct Tax ID" do
      commercial_invoice.tax_id.should  eq  "1234567890"
    end

    ### Coupons --------------------

    it "has no coupons" do
      commercial_invoice.coupons.should eq "None"
    end

    ### Total/subtotal --------------------

    it "should calculate the correct discount" do
      commercial_invoice.discount.to_f.should  eq  -20
    end

    it "should load the correct subtotal" do
      commercial_invoice.subtotal.should eq  90 #@invoices.collect{|invoice| invoice.subtotal}.inject(0, :+)
    end

    it "should load the correct shipping/handling" do
      commercial_invoice.shipping_handling.should  eq  12 #  @invoices.collect{|invoice| invoice.shipping}.inject(0, :+)
    end

    it "should load the correct total" do
      commercial_invoice.total.should eq  102  # @invoices.collect{|i| i.total}.inject(0, :+)
    end

  end

  specify "when there are coupons displays them in the correct format" do
    invoice  # initialize the database rows

    # Add two coupons to the salesorder
    coupons = 2.times.collect { create :coupon }
    coupons.each do |coupon|
      create(:coupon_salesorder, salesorder: @salesorder, coupon: coupon)
    end

    CommercialInvoice.new(invoice).coupons.should eq coupons.collect(&:code).join(", ")
  end

  context "when shipped on our account (default behavior)" do
    before do
      @shipping_account_number = ""
    end

    specify { commercial_invoice.incoterms.should == "CIP" }
    specify { commercial_invoice.shipping_charge_string.should == "Shipping charge" }
  end

  context "when shipped with the customer's account" do
    before do
      @shipping_account_number = "12345"
    end

    specify { commercial_invoice.incoterms.should == "FCA Las Vegas" }
    specify { commercial_invoice.shipping_charge_string.should == "Handling Fee" }
  end

  describe ".pdf" do
    before(:all) { invoice }

    it "returns pdf data when passed just an invoice object" do
      CommercialInvoice.pdf(invoice).should be_an_instance_of String
    end

    it "returns data matching that from #pdf" do
      CommercialInvoice.pdf(invoice).should == commercial_invoice.pdf
    end
  end

end
