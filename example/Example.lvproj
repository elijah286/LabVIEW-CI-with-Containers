<?xml version='1.0' encoding='UTF-8'?>
<Project Type="Project" LVVersion="19008000">
	<Property Name="NI.LV.All.SaveVersion" Type="Str">19.0</Property>
	<Property Name="NI.LV.All.SourceOnly" Type="Bool">true</Property>
	<Property Name="NI.Project.Description" Type="Str"></Property>
	<Item Name="My Computer" Type="My Computer">
		<Property Name="server.app.propertiesEnabled" Type="Bool">true</Property>
		<Property Name="server.control.propertiesEnabled" Type="Bool">true</Property>
		<Property Name="server.tcp.enabled" Type="Bool">false</Property>
		<Property Name="server.tcp.port" Type="Int">0</Property>
		<Property Name="server.tcp.serviceName" Type="Str">My Computer/VI Server</Property>
		<Property Name="server.tcp.serviceName.default" Type="Str">My Computer/VI Server</Property>
		<Property Name="server.vi.callsEnabled" Type="Bool">true</Property>
		<Property Name="server.vi.propertiesEnabled" Type="Bool">true</Property>
		<Property Name="specify.custom.address" Type="Bool">false</Property>
		<Item Name="Basic Functions" Type="Folder">
			<Item Name="Add.lvtest" Type="TestItem" URL="../Basic Functions/Add.lvtest">
				<Property Name="utf.test.bind" Type="Str">Add.vi</Property>
				<Property Name="utf.vector.test.bind" Type="Str">63C16D64-FBC8-8BD6-A0B8-5DE124ED8F1A</Property>
			</Item>
			<Item Name="Add.vi" Type="VI" URL="../Basic Functions/Add.vi"/>
			<Item Name="Divide by Zero.lvtest" Type="TestItem" URL="../Basic Functions/Divide by Zero.lvtest">
				<Property Name="utf.test.bind" Type="Str">Divide.vi</Property>
				<Property Name="utf.vector.test.bind" Type="Str">61D27C2D-9060-2DA7-1543-15F015372E65</Property>
			</Item>
			<Item Name="Divide.lvtest" Type="TestItem" URL="../Basic Functions/Divide.lvtest">
				<Property Name="utf.test.bind" Type="Str">Divide.vi</Property>
				<Property Name="utf.vector.test.bind" Type="Str">82EB2550-E334-0066-05C5-BAEB790AD066</Property>
			</Item>
			<Item Name="Divide.vi" Type="VI" URL="../Basic Functions/Divide.vi"/>
			<Item Name="Multiply.lvtest" Type="TestItem" URL="../Basic Functions/Multiply.lvtest">
				<Property Name="utf.test.bind" Type="Str">Multiply.vi</Property>
				<Property Name="utf.vector.test.bind" Type="Str">57BF4572-2CB9-D844-B2C4-6EE6A8D1C152</Property>
			</Item>
			<Item Name="Multiply.vi" Type="VI" URL="../Basic Functions/Multiply.vi"/>
			<Item Name="Subtract.lvtest" Type="TestItem" URL="../Basic Functions/Subtract.lvtest">
				<Property Name="utf.test.bind" Type="Str">Subtract.vi</Property>
				<Property Name="utf.vector.test.bind" Type="Str">91F62AC1-1827-F199-5DD3-F52E2B350AB7</Property>
			</Item>
			<Item Name="Subtract.vi" Type="VI" URL="../Basic Functions/Subtract.vi"/>
			<Item Name="Waveforms.lvlib" Type="Library" URL="../Basic Functions/Waveforms.lvlib"/>
		</Item>
		<Item Name="Curriculum" Type="Folder" URL="../Curriculum">
			<Property Name="NI.DISK" Type="Bool">true</Property>
		</Item>
		<Item Name="User-Defined Test" Type="Folder">
			<Item Name="Example.css" Type="Document" URL="../User-Defined Test/Example.css"/>
			<Item Name="Untitled.lvtest" Type="TestItem" URL="../Untitled.lvtest">
				<Property Name="utf.vector.test.bind" Type="Str">CDE2EE68-5237-75F3-46ED-C965091E7211</Property>
			</Item>
			<Item Name="User-Defined Advanced.lvtest" Type="TestItem" URL="../User-Defined Test/User-Defined Advanced.lvtest">
				<Property Name="utf.test.bind" Type="Str">VI Under Test.vi</Property>
				<Property Name="utf.vector.test.bind" Type="Str">61EAC8C5-E35E-592E-5D82-33F46F680054</Property>
			</Item>
			<Item Name="User-Defined Basic.lvtest" Type="TestItem" URL="../User-Defined Test/User-Defined Basic.lvtest">
				<Property Name="utf.test.bind" Type="Str">VI Under Test.vi</Property>
				<Property Name="utf.vector.test.bind" Type="Str">A982029D-A6A2-D24D-B326-55ADFE083C8C</Property>
			</Item>
			<Item Name="User-Defined Test Advanced.vi" Type="VI" URL="../User-Defined Test/User-Defined Test Advanced.vi"/>
			<Item Name="User-Defined Test Basic.vi" Type="VI" URL="../User-Defined Test/User-Defined Test Basic.vi"/>
			<Item Name="User-Defined Test.aliases" Type="Document" URL="../User-Defined Test/User-Defined Test.aliases"/>
			<Item Name="VI Under Test.vi" Type="VI" URL="../User-Defined Test/VI Under Test.vi"/>
		</Item>
		<Item Name="Controller Commands.ctl" Type="VI" URL="../Controller Commands.ctl"/>
		<Item Name="Curriculum Launcher.vi" Type="VI" URL="../Curriculum Launcher.vi"/>
		<Item Name="Find Curriculum.vi" Type="VI" URL="../Find Curriculum.vi"/>
		<Item Name="Graph Popup.vi" Type="VI" URL="../Graph Popup.vi"/>
		<Item Name="main.vi" Type="VI" URL="../main.vi"/>
		<Item Name="Status String Update.vi" Type="VI" URL="../Status String Update.vi"/>
		<Item Name="Dependencies" Type="Dependencies"/>
		<Item Name="Build Specifications" Type="Build"/>
	</Item>
</Project>
