module RoutingTableP{
	uses interface LinkStateRouting;

	//Uses this to store the adjacency list that represents the topology
	uses interface List<Node> as AdjacencyList;
	
	//Uses these to run Dijkstras Algorithm
	uses interface List<RouteEntry> as Confirmed;
	uses interface List<RouteEntry> as Tentative;
	
	//Uses this to store the routing table
	uses interface Hashmap<RouteEntry> as Table;
}
implementation{

}
