{
    "name": "Atelier Meubles - Production et maintenance",
    "version": "18.0.1.5.0",
    "category": "Manufacturing",
    "summary": "Étude des devis, ateliers de fabrication et maintenance des machines",
    "license": "LGPL-3",
    "depends": [
        "crm", "sale_management", "sale_crm", "purchase", "stock",
        "mrp", "sale_mrp", "maintenance",
    ],
    "data": [
        "data/workcenters.xml",
        "views/sale_order_views.xml",
        "views/mrp_bom_views.xml",
        "views/maintenance_views.xml",
    ],
    "installable": True,
    "application": True,
    "post_init_hook": "post_init_hook",
}
