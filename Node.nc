/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"
#include "includes/TCP.h"

module Node{
	uses interface Boot;

	uses interface SplitControl as AMControl;
	uses interface Receive;

	uses interface SimpleSend as Sender;
	uses interface SimpleSend as Flooder;
	
	uses interface NeighborDiscovery;
	uses interface LinkStateRouting;
	uses interface Transport;
	uses interface TransportObject;			//Interface handling server/client opening/closing
	uses interface Chat;
	uses interface CommandHandler;
   
	uses interface Timer<TMilli> as RoutingTimer;
}

implementation{
   pack sendPackage;

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

   event void Boot.booted(){
      call AMControl.start();
	  call Transport.start();
	  //NeighborDiscovery.start();
      dbg(GENERAL_CHANNEL, "Booted\n");
   }
   
   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         dbg(GENERAL_CHANNEL, "Radio On\n");
      }else{
         //Retry until successful
         call AMControl.start();
      }
      call NeighborDiscovery.run();
      call RoutingTimer.startPeriodic(1024*8);
   }

   event void AMControl.stopDone(error_t err){}
   
   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
      if(len==sizeof(pack)){
         pack* myMsg=(pack*) payload;
         uint8_t nextHop;
		 uint8_t immHop;
		
		 if(myMsg->protocol == PROTOCOL_TCP) {
			if (myMsg->dest != TOS_NODE_ID) {
				immHop = call LinkStateRouting.getNextHopTo(myMsg->dest);
				call Sender.send(*myMsg, immHop);	//get to final destination
				//dbg(TRANSPORT_CHANNEL, "Wrong node. Forwarding...\n");
			} else if (myMsg->dest == TOS_NODE_ID) {
				//dbg(TRANSPORT_CHANNEL, "Correct node; going to TCP receive...\n");
				call Transport.receive(myMsg);
			}
			//dbg(TRANSPORT_CHANNEL, "We're here\n");
		 }
         if(myMsg->protocol == PROTOCOL_PING) {	
		     	dbg(FLOODING_CHANNEL, "Package recieved\n");
		      if(myMsg->dest == AM_BROADCAST_ADDR) {
		      	dbg(FLOODING_CHANNEL, "Package Payload: %s\n", myMsg->payload);
		      	call Flooder.send(*myMsg, myMsg->dest);
		      }
		      else if(myMsg->dest != TOS_NODE_ID) {
		      	nextHop = call LinkStateRouting.getNextHopTo(myMsg->dest);
		      	dbg(FLOODING_CHANNEL, "Package meant for %d. Forwarding to next hop: %d\n", myMsg->dest, nextHop);
		      	call Sender.send(*myMsg, nextHop);
		      }
		      else {
		         dbg(FLOODING_CHANNEL, "Package Payload: %s\n", myMsg->payload);
		      }
		   }
         
         return msg;
      }
      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
      return msg;
   }

	event void RoutingTimer.fired() {
		call LinkStateRouting.run();
	}

	//event void NeighborDiscovery.changed(uint8_t id) { }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
   	uint8_t nextHop = call LinkStateRouting.getNextHopTo(destination);
      dbg(GENERAL_CHANNEL, "PING EVENT\n");
      makePack(&sendPackage, TOS_NODE_ID, destination, 0, 0, 0, payload, PACKET_MAX_PAYLOAD_SIZE);
      call Sender.send(sendPackage, nextHop);
      //call Flooder.send(sendPackage, destination); //To show packet flooding
   }
   
   event void CommandHandler.printNeighbors(){
   	call NeighborDiscovery.print();
   }

   event void CommandHandler.printRouteTable(){
   	call LinkStateRouting.print();
   }

   event void CommandHandler.printLinkState(){
   	call LinkStateRouting.print();
   }

   event void CommandHandler.printDistanceVector(){}
   
   event void CommandHandler.setTestServer(uint8_t port){

		dbg(TRANSPORT_CHANNEL, "Node %u Listening With Port %u\n", TOS_NODE_ID, port);
		//printf("Hello2\n"); //probing
		call TransportObject.startServer(port);	//we're @ TOS_NODE_ID; implicit server node
		//startServer done in a transport object to handle the opening. Binding done within TransportP but the object handles the process as a whole.
		call Chat.startServer();
		//uint8_t nextHop = call LinkStateRouting.getNextHopTo(destination);
		//dbg(TRANSPORT_CHANNEL, "Server Event\n");
		//makePack(&sendPackage, TOS_NODE_ID, destination, 0, 0, 0, payload, PACKET_MAX_PAYLOAD_SIZE);
		//call Sender.send(sendPackage, nextHop);
   }

   event void CommandHandler.setTestClient(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint16_t data){
	
		dbg(TRANSPORT_CHANNEL, "Node %u Attempting to Establish a Connection With Port %u to Port %u on Node %u. Data Size(B): %u bytes\n", TOS_NODE_ID, srcPort, destPort, dest, data*2);	//mult data by 2 because of header size + payload size?
		//printf("Hello\n"); //probing
	
		call TransportObject.startClient(dest, srcPort, destPort, data);
		//startClient done in TransportObject for the same reasons as startServer above
	
		//uint8_t nextHop = call LinkStateRouting.getNextHopTo(destination);
		//dbg(TRANSPORT_CHANNEL, "Client Event\n");
		//makePack(&sendPackage, TOS_NODE_ID, destination, 0, 0, 0, payload, PACKET_MAX_PAYLOAD_SIZE);
		//call Sender.send(sendPackage, nextHop);
   }

   event void CommandHandler.setClientClose(uint8_t dest, uint8_t srcPort, uint8_t destPort) {
        dbg(TRANSPORT_CHANNEL, "Node %u Attempting to Close an Established Connection From Port %u to Port %u on Node %u.\n", TOS_NODE_ID, srcPort, destPort, dest);
		//printf("Hi\n"); //probing
		
		call TransportObject.closeClient(srcPort, destPort, dest);
		//closeClient done in TransportObject for the same reasons as startServer and startClient above
    }
   
   event void CommandHandler.setChat(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transfer, uint8_t* username){
		call Chat.startChat(dest, srcPort, destPort, transfer, username);
   }
   
   event void CommandHandler.startBroadcast(uint8_t* message){
		call Chat.broadcastMsg(message);
   }
   
   event void CommandHandler.unicast(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint8_t* message){
		dbg(TRANSPORT_CHANNEL, "Node %u Sending Message %s to Node %u\n", TOS_NODE_ID, message, dest);
		call TransportObject.whisperMsg(TOS_NODE_ID, dest, srcPort, destPort, message);
   }
   
   event void CommandHandler.userList(){
		call Chat.printUsers();
   }
   
   event void CommandHandler.setAppServer(){}

   event void CommandHandler.setAppClient(){}

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }
}
