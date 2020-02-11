configuration ChatC {
    provides interface Chat;
}

implementation {
    components ChatP;
    Chat = ChatP;
	
	components TransportC as Transport;
	ChatP.Transport -> Transport;
	
    components new SimpleSendC(AM_PACK);
    ChatP.Sender -> SimpleSendC;

    components new TimerMilliC() as myTimer;
    ChatP.myTimer -> myTimer;

    components RandomC as Random;
    ChatP.Random -> Random;

    components new HashmapC(uint8_t, 20) as Connections;
    ChatP.Connections -> Connections;
	
	components TransportObjectC;
	ChatP.TransportObject -> TransportObjectC;
}