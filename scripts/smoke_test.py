"""Run with: Get-Content scripts/smoke_test.py -Raw | docker compose run -T --rm init odoo shell -d atelier_meubles

The transaction is rolled back, so no demo customer or products remain.
"""

from odoo import Command, fields


try:
    partner = env["res.partner"].create({"name": "Client test - atelier meubles"})
    material = env["product.product"].create(
        {"name": "Panneau test", "is_storable": True, "purchase_ok": True}
    )
    manufacture = env.ref("mrp.route_warehouse0_manufacture")
    mto = env.ref("stock.route_warehouse0_mto")
    assert mto.active, "La route MTO doit être activée par le module"
    workshop = env.ref("atelier_meubles.workcenter_menuiserie_decoupe")
    upholstery = env.ref("atelier_meubles.workcenter_tapisserie_couture")
    products = []
    for name in ["Bureau test", "Banquette test"]:
        product = env["product.product"].create(
            {
                "name": name,
                "is_storable": True,
                "sale_ok": True,
                "route_ids": [Command.set([mto.id, manufacture.id])],
            }
        )
        bom = env["mrp.bom"].create(
            {
                "product_tmpl_id": product.product_tmpl_id.id,
                "product_qty": 1.0,
                "bom_line_ids": [
                    Command.create({"product_id": material.id, "product_qty": 1.0})
                ],
            }
        )
        bom.action_add_furniture_route()
        bom.action_add_furniture_route()
        assert len(bom.operation_ids) == 12
        products.append(product)

    order = env["sale.order"].create(
        {
            "partner_id": partner.id,
            "order_line": [
                Command.create(
                    {
                        "product_id": products[0].id,
                        "product_uom_qty": 1.0,
                        "price_unit": 400.0,
                        "furniture_material_cost": 100.0,
                        "furniture_labor_cost": 80.0,
                        "furniture_other_cost": 20.0,
                    }
                ),
                Command.create(
                    {
                        "product_id": products[1].id,
                        "product_uom_qty": 1.0,
                        "price_unit": 300.0,
                        "furniture_material_cost": 80.0,
                        "furniture_labor_cost": 70.0,
                        "furniture_other_cost": 10.0,
                    }
                ),
            ],
        }
    )
    assert order.furniture_material_estimate == 180.0
    assert order.furniture_total_estimate == 360.0
    assert order.furniture_expected_margin == 340.0
    order.action_confirm()
    productions = order.mrp_production_ids
    assert len(productions) == 2, f"Expected 2 OF, got {len(productions)}"
    assert set(productions.product_id.ids) == set(p.id for p in products)
    for production in productions:
        if production.state == "draft":
            production.action_confirm()
        assert len(production.workorder_ids) == 12, (
            f"Expected 12 OT for {production.name}, got {len(production.workorder_ids)}"
        )
    assert order.picking_ids.filtered(lambda picking: picking.picking_type_code == "outgoing")

    supplier = env["res.partner"].create(
        {"name": "Fournisseur test - atelier meubles", "supplier_rank": 1}
    )
    purchase = env["purchase.order"].create(
        {
            "partner_id": supplier.id,
            "order_line": [
                Command.create(
                    {
                        "product_id": material.id,
                        "name": material.name,
                        "product_qty": 10.0,
                        "product_uom": material.uom_po_id.id,
                        "price_unit": 20.0,
                        "date_planned": fields.Datetime.now(),
                    }
                )
            ],
        }
    )
    purchase.button_confirm()
    assert purchase.picking_ids.filtered(
        lambda picking: picking.picking_type_code == "incoming"
    )

    equipment = env["maintenance.equipment"].create(
        {"name": "Scie test", "furniture_workcenter_id": workshop.id}
    )
    request = env["maintenance.request"].create(
        {
            "name": "Entretien de la scie test",
            "equipment_id": equipment.id,
            "maintenance_type": "preventive",
            "furniture_production_id": productions[0].id,
            "furniture_workorder_id": productions[0].workorder_ids[0].id,
        }
    )
    assert request.equipment_id.furniture_workcenter_id == workshop
    print("OK: 2 meubles, coûts, 2 OF, 12 OT/OF, achat, livraison et maintenance")
finally:
    env.cr.rollback()
