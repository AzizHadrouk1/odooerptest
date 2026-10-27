def migrate(cr, version):
    """Enable MTO for databases created with an earlier module version."""
    cr.execute(
        """
        UPDATE stock_route
           SET active = TRUE
         WHERE id = (
             SELECT res_id
               FROM ir_model_data
              WHERE module = 'stock'
                AND name = 'route_warehouse0_mto'
                AND model = 'stock.route'
         )
        """
    )
