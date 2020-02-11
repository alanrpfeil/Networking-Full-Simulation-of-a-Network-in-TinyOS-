interface CommandHandler{
   // Events
   event void ping(uint16_t destination, uint8_t *payload);
   event void printNeighbors();
   event void printRouteTable();
   event void printLinkState();
   event void printDistanceVector();
   event void setTestServer(uint8_t port);
   event void setTestClient(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint16_t data);
   event void setClientClose(uint8_t dest, uint8_t srcPort, uint8_t destPort);
   event void setChat(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transfer, uint8_t* username);
   event void startBroadcast(uint8_t* message);
   event void unicast(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint8_t* message);
   event void userList();
   event void setAppServer();
   event void setAppClient();
}
