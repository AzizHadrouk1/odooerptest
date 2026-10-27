from odoo import fields, models


class MaintenanceEquipment(models.Model):
    _inherit = "maintenance.equipment"

    furniture_workcenter_id = fields.Many2one(
        "mrp.workcenter",
        string="Atelier / phase",
        help="Centre de travail où cette machine est utilisée.",
        check_company=True,
    )


class MaintenanceRequest(models.Model):
    _inherit = "maintenance.request"

    furniture_production_id = fields.Many2one(
        "mrp.production",
        string="Ordre de fabrication concerné",
        check_company=True,
    )
    furniture_workorder_id = fields.Many2one(
        "mrp.workorder",
        string="Ordre de travail concerné",
        check_company=True,
    )
