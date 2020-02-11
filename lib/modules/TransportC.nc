#include "../../includes/socket.h"

configuration TransportC{
	provides interface Transport;
}

implementation{
components TransportP;
Transport = TransportP;

//components new HashmapC(socket_store_t, 255) as socketPort;
//TransportP.socketPort -> socketPort;

components LinkStateRoutingC as LinkStateRouting;
TransportP.LinkStateRouting -> LinkStateRouting;

components new TimerMilliC() as myTimer;
TransportP.myTimer -> myTimer;

components RandomC as Random;
TransportP.Random -> Random;

components new SimpleSendC(AM_PACK) as Sender;
TransportP.Sender -> Sender;

components new HashmapC(uint8_t, 20) as SocketMap;
TransportP.SocketMap -> SocketMap;

}