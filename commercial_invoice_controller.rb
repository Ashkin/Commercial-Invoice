# Serves commercial invoices

class CommercialInvoiceController < ApplicationController
  before_filter  :bypass_session_check

  def generate
    if not ["preview","test","development"].include? Rails.env
      return render :status => :forbidden, :text => "Error 403: Forbidden"
    end

    raise ActionController::RoutingError, "No Invoice ID specified" if params["id"].nil?
    
    invoice = Invoice.find_by_pkstring(vparams[:id])
    raise ActionController::RoutingError, "No invoice found!" if invoice.nil?
    
    pdf = invoice.generate_commercial_invoice
    send_data pdf, :type=>"application/pdf", :disposition=>"inline"
  end

end
