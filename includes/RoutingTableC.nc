configuration RoutingTableC{
}
implementation {
	components LinkStateRoutingC;
	RoutingTableP.LinkStateRouting -> LinkStateRoutingC;
	
	components new ListC(Node, 20) as AdjacencyList;
	RoutingTableP.AdjacenctList -> AdjacencyList;
	
	components new ListC(RouteEntry, 20) as Confirmed;
	RoutingTableP.Confirmed -> Confirmed;
	
	components new ListC(RouteEntry, 20) as Tentative;
	RoutingTableP.Tentative -> Tentative;
	
	components new Hashmap(RouteEntry, 20) as Table;
	RoutingTableP.Table -> Table;
}
