module AdversarialReview
  def self.root
    File.expand_path("../..", __dir__)
  end
end

require_relative "adversarial_review/schema"
