class UsageController < ApplicationController
  # The page itself is public; it asks for the API token and sends it with each stats call.
  skip_before_action :authenticate_request, only: [:page]

  def page
    render plain: File.read(Rails.root.join("public", "usage.html")), content_type: "text/html"
  end

  def stats
    unless Usage.enabled?
      render json: { error: "usage analytics are off: set MONGODB_URI" }, status: :service_unavailable
      return
    end
    hours = params[:hours].to_i
    hours = 24 unless hours.between?(1, 24 * 90)
    render json: Usage.stats(hours, errors_only: params[:logs] == "errors")
  rescue StandardError => e
    render json: { error: "#{e.class}: #{e.message}" }, status: :service_unavailable
  end
end
