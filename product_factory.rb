FactoryGirl.define do
  factory :product_internal do
    not_physical_item    false
    exclude_from_customs false
  end
end

FactoryGirl.define do
  factory :product do
    sequence :name do |n|
      "Super-awesome product ##{n}"
    end

    weight_ounces do
      if not_physical_item
        0
      else
        2
      end
    end

    sequence :country_of_origin, ["USA", "China", "Italy"].cycle

    sequence :export_code, ["222222", "444444", "555555"].cycle

    # Use this trait to generate a product that is a combination consisting of
    # other products.
    # NOTE: This trait does not actually generate any of the constituent products
    # or the product_combination records that are needed.
    trait :combination do
      sequence :name do |n|
        "Super-awesome product combination ##{n}"
      end
      country_of_origin "USA"
      export_code ""
    end

    # Use this trait to generate a product that represents a discount.
    trait :discount do
      sequence :name do |n|
        "Super-awesome discount ##{n}"
      end
  
      not_physical_item true
      export_code ""
    end

    # The 'specs' attribute is for product specifications (e.g. Max Current).
    # Example usage:
    #   amps = create :unit, name: "A"
    #   parameter = create :parameter, name: "max current", is_decimal: true, standard_unit: amps
    #   create :product, :specs => { parameter => 2.0 }
    ignore do
      specs Hash[]
    end
    after(:create) do |product, evaluator|
      evaluator.specs.each do |parameter, value|
        create :specification, owner: product,
          parameter: parameter, unit: parameter.standard_unit, value: value
      end
    end

    ### product_internal ###
    ignore do
      not_physical_item false
      exclude_from_customs false
      distributor_pricing_note ""
      our_unit_cost 0
      restock_threshold 100
    end

    product_internal do |p, e|
      create :product_internal,
        not_physical_item: not_physical_item,
        exclude_from_customs: exclude_from_customs,
        distributor_pricing_note: distributor_pricing_note,
        our_unit_cost: our_unit_cost,
        restock_threshold: restock_threshold
    end

  end
end
