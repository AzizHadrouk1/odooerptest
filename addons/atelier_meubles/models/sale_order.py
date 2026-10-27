from odoo import api, fields, models


class SaleOrder(models.Model):
    _inherit = "sale.order"

    furniture_study_state = fields.Selection(
        [
            ("requested", "Demande reçue"),
            ("in_study", "Étude en cours"),
            ("ready", "Devis prêt"),
            ("approved", "Étude validée"),
        ],
        string="Avancement de l'étude",
        default="requested",
        tracking=True,
    )
    furniture_requirements = fields.Text(string="Demande et dimensions du client")
    furniture_study_notes = fields.Text(string="Étude technique et plan de fabrication")
    furniture_material_estimate = fields.Monetary(
        string="Coût total estimé des matières",
        currency_field="currency_id",
        compute="_compute_furniture_estimates",
    )
    furniture_total_estimate = fields.Monetary(
        string="Coût total estimé de la demande",
        currency_field="currency_id",
        compute="_compute_furniture_estimates",
    )
    furniture_expected_margin = fields.Monetary(
        string="Marge estimée (hors taxes)",
        currency_field="currency_id",
        compute="_compute_furniture_estimates",
    )

    @api.depends(
        "order_line.display_type",
        "order_line.is_downpayment",
        "order_line.product_uom_qty",
        "order_line.furniture_material_cost",
        "order_line.furniture_total_cost",
        "order_line.furniture_expected_margin",
    )
    def _compute_furniture_estimates(self):
        for order in self:
            lines = order.order_line.filtered(
                lambda line: not line.display_type and not line.is_downpayment
            )
            order.furniture_material_estimate = sum(
                line.furniture_material_cost * line.product_uom_qty for line in lines
            )
            order.furniture_total_estimate = sum(lines.mapped("furniture_total_cost"))
            order.furniture_expected_margin = sum(lines.mapped("furniture_expected_margin"))


class SaleOrderLine(models.Model):
    _inherit = "sale.order.line"

    furniture_study_notes = fields.Text(string="Étude technique de ce meuble")
    furniture_material_cost = fields.Monetary(
        string="Matières / unité", currency_field="currency_id"
    )
    furniture_labor_cost = fields.Monetary(
        string="Main-d'œuvre / unité", currency_field="currency_id"
    )
    furniture_other_cost = fields.Monetary(
        string="Autres coûts / unité", currency_field="currency_id"
    )
    furniture_unit_cost = fields.Monetary(
        string="Coût estimé / unité",
        currency_field="currency_id",
        compute="_compute_furniture_costs",
        store=True,
    )
    furniture_total_cost = fields.Monetary(
        string="Coût estimé de la ligne",
        currency_field="currency_id",
        compute="_compute_furniture_costs",
        store=True,
    )
    furniture_expected_margin = fields.Monetary(
        string="Marge estimée de la ligne",
        currency_field="currency_id",
        compute="_compute_furniture_costs",
        store=True,
    )

    @api.depends(
        "furniture_material_cost",
        "furniture_labor_cost",
        "furniture_other_cost",
        "product_uom_qty",
        "price_subtotal",
        "display_type",
        "is_downpayment",
    )
    def _compute_furniture_costs(self):
        for line in self:
            if line.display_type or line.is_downpayment:
                line.furniture_unit_cost = 0.0
                line.furniture_total_cost = 0.0
                line.furniture_expected_margin = 0.0
                continue
            line.furniture_unit_cost = (
                line.furniture_material_cost
                + line.furniture_labor_cost
                + line.furniture_other_cost
            )
            line.furniture_total_cost = line.furniture_unit_cost * line.product_uom_qty
            line.furniture_expected_margin = line.price_subtotal - line.furniture_total_cost
