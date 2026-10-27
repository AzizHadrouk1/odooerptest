from odoo import models, _
from odoo.exceptions import UserError


class MrpBom(models.Model):
    _inherit = "mrp.bom"

    def action_add_furniture_route(self):
        """Add the requested workshop phases to a furniture BoM, once each."""
        self.ensure_one()
        if self.type != "normal":
            raise UserError(_("Le parcours complet nécessite une nomenclature de fabrication."))

        workcenter_xmlids = [
            "workcenter_magasin_kit",
            "workcenter_menuiserie_decoupe",
            "workcenter_menuiserie_usinage",
            "workcenter_menuiserie_assemblage",
            "workcenter_menuiserie_finition",
            "workcenter_menuiserie_peinture",
            "workcenter_tapisserie_garnissage",
            "workcenter_tapisserie_moussage",
            "workcenter_tapisserie_coupe_tissu",
            "workcenter_tapisserie_couture",
            "workcenter_tapisserie_finition",
            "workcenter_conditionnement_emballage",
        ]
        existing_workcenter_ids = set(self.operation_ids.workcenter_id.ids)
        for sequence, xmlid in enumerate(workcenter_xmlids, start=1):
            workcenter = self.env.ref(f"atelier_meubles.{xmlid}")
            if workcenter.id in existing_workcenter_ids:
                continue
            self.env["mrp.routing.workcenter"].create(
                {
                    "bom_id": self.id,
                    "name": workcenter.name,
                    "workcenter_id": workcenter.id,
                    "sequence": sequence * 10,
                    "time_cycle": 30.0,
                }
            )
        return True
