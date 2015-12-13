# Class for generating commercial invoice PDFs for the shipping department.

class CommercialInvoice

  class InvoiceError < StandardError;  end

  class Row < Struct.new(:line_number, :quantity, :product_id, :description,
    :extended_weight, :unit_price, :extended_price, :origin, :hs_code)

    def self.normal(line_number, invoice_line_item)
      product = invoice_line_item.salesorder_line_item.product
      product_internal = product.product_internal
      self[line_number,
           (product_internal.not_physical_item ? "-" : invoice_line_item.quantity),
           product.pk,
           invoice_line_item.name,
           (product_internal.not_physical_item ? "-" : "%g" % (invoice_line_item.quantity * product.weight_ounces) + " oz"),
           "%.2f"%invoice_line_item.unit_price,
           "%.2f"%invoice_line_item.extended_price,
           product.country_of_origin,
           get_hs_code_for_product(product)]
    end

    def self.combination_item(line_number, invoice_line_item)
      product = invoice_line_item.salesorder_line_item.product
      product_internal = product.product_internal

      # potentially buggy:  handles non-positive (<=0) quantites, but those should never happen anyway.
      combo_contains_string = (invoice_line_item.quantity == 1 ? "This Combo contains" : "These collectively contain")

      self[line_number,
           "-",    # Don't display quantity here
           product.pk,
           "<b>#{invoice_line_item.quantity}x Combo:</b>  #{invoice_line_item.name}\n<u><i>#{combo_contains_string}</i></u>:",   # Display quantity here instead, and blatantly mark as a Combo for customs.
           (product_internal.not_physical_item ? "-" : "%g" % (invoice_line_item.quantity * product.weight_ounces) + " oz"),  # display a - for non-physical item weight.
           "%.2f"%invoice_line_item.unit_price,
           "%.2f"%invoice_line_item.extended_price,
           product.country_of_origin,
           get_hs_code_for_product(product)]
    end

    # production_combination: ProductCombination row from the database
    # quantity: The quantity of this combo product that was ordered.
    def self.combination_subitem(line_number, product_combination, quantity)
      product = product_combination.product
      product_internal = product.product_internal
      self[line_number,
           (product_internal.not_physical_item ? "-" : (quantity * product_combination.quantity).to_s),
           product.pk,
           product.name,
           "",
           "",
           "",
           product.country_of_origin,
           get_hs_code_for_product(product)]
    end


    # Convert a schedule_b code into an international HS code
    # by stripping the dots and removing the last four digits
    # as they are are country-specific, and so thereby do not
    # belong on an international invoice.

    # See makeHsCode() in system2/src/browsers/package/PackageController.cs
    def self.get_hs_code_for_product(product)
      return product.current_assembly.schedule_b_code.gsub(/\./,"")[0..5]   if product.assembly.first
    end
  end

  attr_reader :invoices,                # Invoice objects
              :main_invoice,
              :main_package,
              :invoice,                 # Invoice ID
              :salesorder,              # Salesorder ID
              :addr_from,               # Hardcoded,
              :contact,                 # Contact object
              :addr_consignee,          # Shipping address.  importer is a copy of this
              :addr_importer,
              :tax_id,                  # Customer's Tax ID
              :items,                   # Line items (and table header)
              :total_quantity,          # Number of physical items
              :total_weight,
              :shipping_charge_string,  # "handling fee" vs "shipping charge"
              :prediscount_total,       # Subtotal before discounts
              :coupons,
              :incoterms,
              :discount,                # Total discounts
              :subtotal,
              :tax,                     # Amount of tax
              :shipping_handling,       # Shipping/handling fee
              :total

  def initialize(invoice)
    raise ArgumentError, "Invalid invoice specified: #{invoice}" if not invoice.is_a? Invoice
    generate invoice
  end

  def self.pdf(invoice)
    new(invoice).pdf
  end

  # Returns the PDF as a binary string.
  def pdf
    @pdf ||= construct_pdf
  end

  # This is here just to make it more convenient to test the commercial invoice code.
  def save_pdf(filename)
    File.open(filename, "wb:ASCII-8BIT") { |f| f << pdf }
  end

  # should display all of these, though they may not all have values.
  def shipping_info
    shipping_info = {}
    shipping_info["Ship Date"]   = (main_invoice.ship_time.try(:to_date) || Date.today.strftime("%Y-%m-%d")).to_s
    shipping_info["Ship Method"] =  main_invoice.shipping_service
    shipping_info["Tracking #"]  =  main_package.tracking_number
    shipping_info["Invoice" + ("s" if @invoice.include? ",").to_s] = @invoice
    shipping_info["PO Number"]   =  main_invoice.salesorder.po    if not main_invoice.salesorder.po.empty?

    shipping_info.each do |key, value|
      shipping_info[key] = "none" if value.empty?
    end

    shipping_info
  end

private

  #  takes a contact object and returns an array of all the pertinent info, sans blank lines and erroneous text
  def construct_address_from_contact(contact)
    array = []
    address = contact.address.first

    raise InvoiceError, "contact name is missing"    if contact.name.first.to_s.empty?
    raise InvoiceError, "address line 1 is missing"  if address.addr1.empty?

    array << contact.name.first.to_s
    array << address.addr1
    array << address.addr2
    array << address.addr3

    #  City, State  ZIP   (all optional)
    temp = ""
    temp += address.city          if address.city.length  > 0
    temp += ", "                  if address.state.length > 0  and temp.length > 0
    temp += address.state         if address.state.length > 0
    temp += "  " + address.zip    if address.zip.length   > 0
    array << temp
    
    array << address.country
    array << "Phone: " + contact.phone.first.string_number  if contact.phone.first.string_number.length > 0
    array << contact.email_address.first.email
    
    return array.reject(&:empty?)
  end



  def generate(invoice)
    @main_invoice = invoice
    
    packages = @main_invoice.package
    raise InvoiceError, "Expected invoice to have exactly 1 package" if packages.size != 1
    @main_package = packages.first

    # Get all invoices that are shipping with this one.
    @invoices = @main_package.same_packages.collect(&:invoice)
    
    raise InvoiceError, "Invoices array empty"             if invoices.empty?
    raise InvoiceError, "Invoice has no items"             if main_invoice.line_item.empty?
    raise InvoiceError, "Invoice has no shipping contact"  if main_invoice.shipping_contact.nil?
    raise InvoiceError, "Package weight is zero"           if main_package.weight_ounces == 0

    @salesorder = main_invoice.salesorder.pkstring
    @invoice    = invoices.collect { |invoice| invoice.pkstring }.join(", ")
    
    @contact        = main_invoice.shipping_contact
    @addr_consignee = construct_address_from_contact main_invoice.shipping_contact
    @addr_importer  = @addr_consignee  # consignee and importer are always going to be the same for any auto-generated invoices.
    @addr_from      = ["Jennifer Wolff", "Pololu Corporation", "920 Pilot Road", "Las Vegas, NV 89119", "USA", "Tax ID: 043557128"]  # should fetch this from a central location.
    
    if invoices.first.shipping_account_number.empty?
      # Shipping on our account.
      @shipping_charge_string = "Shipping charge"
      @incoterms              = "CIP"
    else
      # Shipping on customer's account.
      @shipping_charge_string = "Handling Fee"
      @incoterms              = "FCA Las Vegas"
    end

    @prediscount_total = 0
    @discount          = 0
    @items             = []
    line_item_count    = 0   # differs from items.size() as combo subitem indexes are 3a, 3b, 3c, etc.

    # Process each invoice in turn
    invoices.flat_map(&:line_item).each do |item|
      product = item.salesorder_line_item.product
      product_internal = product.product_internal

      next if item.quantity <= 0  # non-positive quantities are irrelevant!

      if item.extended_price < 0 or product.discount?
        # This is a discount item.
        @discount += item.extended_price
        line_item_count += 1
        @items << Row.normal(line_item_count, item)
        next
      end

      # There are some discounts like product 1190 that are marked as "exclude_from_customs"
      # so we need to do this check AFTER handling discount items.
      next if product_internal.exclude_from_customs

      line_item_count += 1  # We are now committed to adding a line.

      constituents = product.child_product_combination

      if !constituents.empty?
        # This invoice line item represents a combination product.

        @items << Row.combination_item(line_item_count, item)

        # these make the code more readable: it isn't very obvious what "item.quantity * citem.quantity", etc. would mean
        combination_total_price = item.extended_price  

        combination_quantity    = item.quantity
        subindex                = "a"  # 3a, 3b, 3c, ...

        # Display all its constituent items
        constituents.each do |citem| 
          next if citem.product.product_internal.exclude_from_customs

          @items << Row.combination_subitem(line_item_count.to_s + subindex, citem, combination_quantity)

          subindex.next!
        end
        
        @prediscount_total += combination_total_price
        next
      end

      # just a normal item
      @items << Row.normal(line_item_count, item)
      @prediscount_total += item.extended_price
    end
    
    @tax_id            = main_invoice.salesorder.tax_id  # should be the same for all invoices.
    @tax               = invoices.map{ |i| i.tax      }.inject(0, :+)
    @subtotal          = invoices.map{ |i| i.subtotal }.inject(0, :+)
    @shipping_handling = invoices.map{ |i| i.shipping }.inject(0, :+)
    @total             = invoices.map{ |i| i.total    }.inject(0, :+)
    @total_weight      = main_package.weight_ounces    # there will only ever be one package per invoice.  in the case of linked invoices, both packages' weights are identical.
    @coupons           = (invoices.map{ |i| i.salesorder.coupon.map{|c| c.code} }).flatten.uniq.join(", ")  # one line to gather all unique coupons from all invoices, and in the darkness bind them.
    @coupons           = "None"  if @coupons.empty?
    @total_quantity    = items.map { |i| i.quantity.to_i }.inject(0, :+)

    # Add table header
    @items.unshift(["#", "Quantity", "Item Number", "Item Description", "Ext. Weight", "Unit Price (USD)", "Extended Price", "Origin", "HS code"])
  end

  # This method generates a PDF using prawn and returns the result as a binary string.
  def construct_pdf
    raise ArgumentError, "Argument missing or invalid: total_weight"            if @total_weight          .to_f <= 0
    raise ArgumentError, "Argument missing or invalid: total"                   if @total                 .to_f <= 0
   #raise ArgumentError, "Argument missing or invalid: subtotal"                if @subtotal              .to_f <= 0    ## free items make it possible that the subtotal is zero
    raise ArgumentError, "Argument missing or invalid: shipping_handling"       if @shipping_handling     .to_f <  0
    raise ArgumentError, "Argument missing or invalid: shipping_charge_string"  if @shipping_charge_string.to_s.length < 1
    raise ArgumentError, "Argument missing or invalid: incoterms"               if @incoterms             .to_s.length < 1
    
    raise Exception,     "Internal error: Invoice discount total is positive! (should always be <= 0)" if @discount.to_f > 0
    

    # Formatting
    tax_id = "Tax ID: #{@tax_id}"   if @tax_id.length > 0
    shipping_charge_string = "#{@shipping_charge_string}: "

    # Create the PDF
    doc = Prawn::Document.new(:top_margin=>106)  # important for aligning!
  
    # normal size: LETTER > 612.00 x 792.00
    doc.font "Helvetica" # Because it's sexy.


    # Header
    doc.repeat(:all) do
      # Fixed string arrays
      pololuHeader  = ["Pololu Corporation", "920 Pilot Road", "Las Vegas, NV 89119", "USA"]
      pololuContact = ["Tel: +1 (702) 262-6648","Fax: +1 (702) 262-6894","sales@pololu.com","www.pololu.com"]  ### email
      titleText     = "Commercial Invoice"
      
      doc.bounding_box [doc.bounds.left, doc.bounds.top+70], :width=>doc.bounds.width, :height=>65 do

        # Pololu logo and address
        doc.image "resource/commercial_invoice/Pololu_BW.jpg", :at=>[-7, 65], :height=>50
        draw_text_block doc, pololuHeader, :at=>[40, 65-15], :size=>8
        
        # Pololu contact info
        doc.text_box pololuContact*"\n", :at=>[430,70-15], :size=>8, :width=>100, :align=>:right
        
        # Title and salesorder
        doc.text_box titleText, :at=>[40, 65-13], :width=>500-40, :size=>20, :align=>:center, :style=>:bold
        doc.text_box "For Salesorder" + (@salesorder.include?(",") ? "s " : " ") + @salesorder.to_s, :at=>[40, 65-35], :width=>500-40, :size=>14, :align=>:center  unless @salesorder.nil?
        
        # Header Rule
        doc.line_width = 3
        doc.stroke { doc.line [40, 65-54], [500, 65-54] }
        doc.line_width = 1

      end

    end


    draw_shipping_info doc

    # Addresses
    addr_consignee = @addr_consignee.dup
    addr_consignee << tax_id.to_s   if tax_id
    draw_address  doc, "Shipped from:", @addr_from,      :at=>[ 10,530]
    draw_address  doc, "Consignee:",     addr_consignee, :at=>[300,640]
    draw_address  doc, "Importer:",     @addr_importer,  :at=>[300,530]


    # Let the cursor catch up
    doc.move_down 230
    
    # Contents List
    item_arrays = @items.collect(&:to_a)
    column_widths = {1=>40, 2=>37, 3=>240, 4=>36, 5=>45, 6=>45, 7=>30, 8=>35}
    doc.table(item_arrays, column_widths: column_widths,
              header:true, row_colors:["ffffff", "f0f0f0"], cell_style:{inline_format:true}) do |t|
      t.cells.size               = 8
      t.cells.borders            = []
      t.cells.padding            = 3
      
      t.row(0).border_bottom_width   = 0.5
      t.column(0).border_right_width = 0.5

      t.column(0).borders        = [:right]
      t.column(0).align          = :left
      t.column(1..2).align       = :center
      t.column(4..6).align       = :right
      t.column(7..8).align       = :center

      t.row(0).borders           = [:bottom]


      
      # per-item custom formatting
      @items.each_with_index do |item, i|
        # any item without a listed weight should have the ext. weight column centered
        t.row(i).column(4).align = :center  if item[4].to_s.include? "-"

        # combo subitems should be easily distinguishable.
        #     so: smaller, italic gray text, and "indented" (right-aligned quantity and product id).
        #    and: hanging-indent on descriptions
        if item[0].to_s.match(/[0-9]+[a-z]+/)   # 3a, 3b, 3c, ...
          t.row(i).size                    = 7
          t.row(i).text_color              = "666666"
          t.row(i).column(1..2).align      = :right
          t.row(i).column(3   ).font_style = :italic
          t.row(i).column(3   ).padding    = [0,0,0,30]
          t.row(i).column(7..8).text_color = "000000"
        end
      end

      # header should be bold
      t.row(0).font_style        = :bold
      t.row(0).column(0).borders = [:bottom, :right]   ### []
    end
    
    # Make sure there's enough space for up to four lines of coupons (Black Friday)
    if doc.cursor < 30 then
      doc.start_new_page
      doc.move_down 25
    end

    # Coupon list
    doc.move_down 4
    doc.text "<b>Coupons used:</b>  " + @coupons,  :size=>6.5, :inline_format=>true
    
    # Table Summary
    quantity_text  = @total_quantity.to_s + " item"
    quantity_text += "s"  if @total_quantity.to_i > 1
    shipmentWeight = ("%.2f"%(@total_weight/16.0)).to_s + " pounds"

    # if there isn't enough room, draw the header on a new page and begin again.
    # (45 height for summary  +  35 height for discount section  +  35 margin)
    if doc.cursor < (@discount.to_f<=0 ? 80 : 45) + 35
      doc.start_new_page
      doc.move_down 40
    else
      summary_separator doc
    end


    # Begin Summaries
    summary_start = doc.cursor
    

    # Right side!   (price summary)
    if @discount.to_f < 0
      summary_text doc, "Before discounts:", "$%.2f"% @prediscount_total, 360, 452
      summary_text doc, "Discounts:",        "$%.2f"% (@discount or 0),   360, 452
      summary_separator doc
    end

    summary_text doc, "Subtotal:",             "$%.2f"% @subtotal,          360, 452, :style=>:bold
    summary_text doc, shipping_charge_string,  "$%.2f"% @shipping_handling, 360, 452
    summary_separator doc
    summary_text doc, "Invoice Total (USD):", "$%.2f"% @total, 360, 452, :style=>:bold


    # Left side!   (Invoice info)
    doc.move_cursor_to summary_start

    [["Total quantity:",  quantity_text ],
     ["Shipment weight:", shipmentWeight],
     ["Incoterms:",       @incoterms    ]].each do |summary_line|
      summary_text doc, summary_line[0], summary_line[1],  0, 120, :width=>100, :style=>:bold, :align=>:left
     end
    

    # if there isn't enough room, draw the header on a new page and begin again.
    # (70 height + 30 margin)
    doc.start_new_page if doc.cursor < 150
    
    doc.move_down 50


    # Closing Text

    # Image first so the text draws over it
    doc.image "resource/commercial_invoice/signature_jennifer.png", :at => [3, doc.cursor-28], :height => 35
    
    # Closing text
    doc.text_box "I declare all information in this invoice to be true and correct.\nSignature of shipper:", :at=>[0,doc.cursor], :width=>500, :size=>12
    doc.move_down 52

    doc.line_width = 1
    doc.stroke { doc.line [0, doc.cursor], [150, doc.cursor] }

    doc.move_down 6
    doc.text_box "Jennifer Wolff", :at=>[8,doc.cursor], :width=>500, :size=>12
    doc.move_down 50


    # Page numbering
    options = {
      :at    => [doc.bounds.right - 150, 0],
      :width => 150,
      :align => :right,
      :size  => 10
    }
    doc.number_pages "Page <page> of <total>", options

    doc.render  # Return binary string containing the PDF.
  end


  # Draw an address with title
  def draw_address(doc, title, address, options)
    doc.draw_text title, {:size=>14, :style=>:bold}.merge(options)
    options[:at][0] += 10
    options[:at][1] -= 15
    draw_text_block doc, address, options
  end


  # Draw the shipping info block (tracking number, salesorders, etc.)
  def draw_shipping_info(doc)
    info = shipping_info

    if false
      # Ashley's code for drawing a fancy shipping tag around the info.

      # auto-stretches based on tracking number, with fedex's 12-char length as the default size
      # 5.5 points per character times (tracking number length minus twelve) or zero, whichever is larger.
      # 145 max size so it doesn't draw over the "Consignee" block,
      # though that won't happen unless tracking numbers get stupidly long
      len = [0, info.values.max_by{|x| x.to_s.length}.length-12].max * 5.5
      len = 145  if len > 145
      
      doc.stroke { doc.line [0,      630], [140+len,630] }
      doc.stroke { doc.line [140+len,630], [160+len,610] }
      doc.stroke { doc.line [160+len,610], [160+len,580] }
      doc.stroke { doc.line [160+len,580], [140+len,560] }
      doc.stroke { doc.line [140+len,560], [0,      560] }
      doc.stroke_circle     [145+len,595],  5

      locations = [ [ 5, 615], [ 70, 615] ]
    else
      locations = [ [20, 620], [100, 620] ]
    end

    # Add colons except for labels that end with "#".
    # labels = info.keys.collect{|k| k[-1]=="#" ? k : k+":"}
    labels = info.keys.collect{|k| k+":"}

    locations[0][1] += 5 * (labels.size-4)
    locations[1][1] += 5 * (labels.size-4)

    draw_text_block doc, labels,      at: locations[0], size: 10, spacing: 14, style: :bold
    draw_text_block doc, info.values, at: locations[1], size: 10, spacing: 14
  end


  # Write a line of summary text (ex: subtotal)
  def summary_text(doc, label, value, x1, x2, options={})
    ops = {
      :at => [x1, doc.cursor],
      :size => 10,
      :height => 10
    }.merge(options)
    doc.text_box label, {:width=>100}.merge(ops)
    ops[:at][0] = x2
    doc.text_box value.to_s, {:width=>50, :align=>:right}.merge(ops)

    doc.move_down 11
  end

  # Summary separator bar
  def summary_separator(doc)
    doc.move_down 1
    doc.stroke { doc.line [350, doc.cursor], [514, doc.cursor] }
    doc.move_down 3
  end


  # draw a series of strings in a block with a given spacing
  def draw_text_block(doc, strings, options={})
    # Default hash values
    options = {
      :size    => 10
    }.merge(options)
    options[:spacing] ||= options[:size]  # spacing should normally be the same as font size.

    strings.each_with_index do |string, index|
      # update :at for each line in the block
      ops = options.merge at: [ options[:at][0], options[:at][1] - options[:spacing]*index ]
      doc.draw_text string, ops
    end
  end

end
